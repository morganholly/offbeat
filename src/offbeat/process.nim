import clap
import types, state
import std/[locks, math, tables]


proc lerp*(x, y, mix: float32): float32 =
    result = (y - x) * mix + x

const pi *: float64 = 3.1415926535897932384626433832795

# based on reaktor one pole lowpass coef calculation
proc onepole_lp_coef*(freq: float64, sr: float64): float64 =
    var input: float64 = min(0.5 * pi, max(0.001, freq) * (pi / sr));
    var tanapprox: float64 = (((0.0388452 - 0.0896638 * input) * input + 1.00005) * input) /
                            ((0.0404318 - 0.430871 * input) * input + 1);
    return tanapprox / (tanapprox + 1);

# based on reaktor one pole lowpass
proc onepole_lp*(last: var float64, coef: float64, src: float64): float64 =
    var delta_scaled: float64 = (src - last) * coef;
    var dst: float64 = delta_scaled + last;
    last = delta_scaled + dst;
    return dst;

proc simple_lp_coef*(freq: float64, sr: float64): float64 =
    var w: float64 = (2 * pi * freq) / sr;
    var twomcos: float64 = 2 - cos(w);
    return 1 - (twomcos - sqrt(twomcos * twomcos - 1));

proc simple_lp*(smooth: var float64, coef: float64, next: float64): var float64 =
    smooth += coef * (next - smooth)
    return smooth

proc offbeat_start_processing*(clap_plugin: ptr ClapPlugin): bool {.cdecl.} =
    var plugin = cast[ptr Plugin](clap_plugin.plugin_data)
    if plugin.cb_on_start_processing != nil:
        return plugin.cb_on_start_processing(plugin)
    return true

proc offbeat_stop_processing*(clap_plugin: ptr ClapPlugin): void {.cdecl.} =
    var plugin = cast[ptr Plugin](clap_plugin.plugin_data)
    if plugin.cb_on_stop_processing != nil:
        plugin.cb_on_stop_processing(plugin)

proc offbeat_reset*(clap_plugin: ptr ClapPlugin): void {.cdecl.} =
    var plugin = cast[ptr Plugin](clap_plugin.plugin_data)
    if plugin.cb_on_reset != nil:
        plugin.cb_on_reset(plugin)

proc offbeat_process_event*(plugin: ptr Plugin, event: ptr ClapEventUnion): void {.cdecl.} =
    # myplug.dsp_controls.level = float32(event.kindParamValMod.val_amt)
    if event.kindParamValMod.header.space_id == 0:
        case event.kindParamValMod.header.event_type: # kindParamValMod for both, as the objects are identical
            of cetPARAM_VALUE: # actual knob changes or automation
                withLock(plugin.controls_mutex):
                    let index = plugin.id_map[uint32(event.kindParamValMod.param_id)]
                    var param_data = plugin.dsp_param_data[index]
                    var param = plugin.params[index]
                    case param.kind:
                        of pkFloat:
                            var last_value = param_data.f_value
                            param_data.f_raw_value = event.kindParamValMod.val_amt
                            param_data.f_next_value = if param.f_remap != nil:
                                                        param.f_remap(event.kindParamValMod.val_amt)
                                                    else:
                                                        event.kindParamValMod.val_amt
                            param_data.has_changed = true # maybe set up converters to set this and automatically handle conversion based on kind
                            case param.f_smooth_mode:
                                of smLerp:
                                    param_data.f_smooth_sample_counter = param_data.f_smooth_samples
                                    param_data.f_smooth_step = (param_data.f_next_value - last_value) / float64(param_data.f_smooth_samples)
                                of smFilter:
                                    discard
                                of smNone:
                                    param_data.f_value = param_data.f_next_value
                        of pkInt:
                            param_data.i_raw_value = int64(event.kindParamValMod.val_amt)
                            param_data.i_value = if param.i_remap != nil:
                                                        param.i_remap(param_data.i_raw_value)
                                                    else:
                                                        param_data.i_raw_value
                            param_data.has_changed = true
                        of pkBool:
                            param_data.b_value = event.kindParamValMod.val_amt > 0.5
                            param_data.has_changed = true
            of cetPARAM_MOD: # per voice modulation
                discard
            else:
                discard

proc offbeat_process*(clap_plugin: ptr ClapPlugin, process: ptr ClapProcess): ClapProcessStatus {.cdecl.} =
    var plugin = cast[ptr Plugin](clap_plugin.plugin_data)

    plugin.sync_ui_to_dsp(process.out_events)

    let num_frames: uint32 = process.frames_count
    let num_events: uint32 = process.in_events.size(process.in_events)
    var event_idx: uint32 = 0
    var next_event_frame: uint32 = if num_events > 0: 0 else: num_frames

    var i: uint32 = 0
    while i < num_frames:
        while event_idx < num_events and next_event_frame == i:
            let event: ptr ClapEventUnion = process.in_events.get(process.in_events, event_idx)
            if event.kindNote.header.time != i:
                next_event_frame = event.kindNote.header.time
                break

            # if event.kindNote.header.event_type == cetPARAM_VALUE:
            #     event.kindParamValMod.val_amt = 1
            offbeat_process_event(plugin, event)
            event_idx += 1

            if event_idx == num_events:
                next_event_frame = num_frames
                break

        # i = next_event_frame
        while i < next_event_frame:
            for p in plugin.smoothed_params:
                if plugin.params[p].kind == pkFloat:
                    var param_data = plugin.dsp_param_data[p]
                    case plugin.params[p].f_smooth_mode:
                        of smLerp:
                            if param_data.f_smooth_sample_counter > 0:
                                param_data.f_value += param_data.f_smooth_step
                                param_data.f_smooth_sample_counter -= 1
                                if plugin.params[p].f_calculate != nil:
                                    plugin.params[p].f_calculate(plugin, param_data.f_value, p)
                        of smFilter:
                            discard simple_lp( # mutates first input
                                        param_data.f_value,
                                        param_data.f_smooth_coef,
                                        param_data.f_next_value)
                            if plugin.params[p].f_calculate != nil:
                                plugin.params[p].f_calculate(plugin, param_data.f_value, p)
                        of smNone:
                            discard
            var is_left_constant  = (process.audio_inputs[0].constant_mask and 0b01) != 0
            var is_right_constant = (process.audio_inputs[0].constant_mask and 0b10) != 0
            if process.audio_inputs[0].data64 != nil:
                plugin.cb_process_sample(
                    plugin,
                    process.audio_inputs[0]. data64[0][if is_left_constant:  0'u32 else: i],
                    process.audio_inputs[0]. data64[1][if is_right_constant: 0'u32 else: i],
                    process.audio_outputs[0].data64[0][i],
                    process.audio_outputs[0].data64[1][i],
                    process.audio_inputs[0].latency)
            else:
                var temp_out_left : float64 = 0
                var temp_out_right: float64 = 0
                plugin.cb_process_sample(
                    plugin,
                    float64(process.audio_inputs[0]. data32[0][if is_left_constant:  0'u32 else: i]),
                    float64(process.audio_inputs[0]. data32[1][if is_right_constant: 0'u32 else: i]),
                    temp_out_left,
                    temp_out_right,
                    process.audio_inputs[0].latency)
                process.audio_outputs[0].data32[0][i] = float32(temp_out_left)
                process.audio_outputs[0].data32[1][i] = float32(temp_out_right)
            i += 1
    return cpsCONTINUE