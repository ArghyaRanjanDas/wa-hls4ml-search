# Catapult flow script to synthesize an existing Keras/QKeras model (.h5)
# via the /HLS4ML flow package.
#
# Usage inside catapult-shell:
#   set model_path /abs/path/to/keras_model.h5
#   set out_dir /abs/path/to/catapult_native
#   set reuse_factor 16
#   set run_synth 1
#   dofile /abs/path/to/util/catapult_hls4ml_flow.tcl
#
# Optional vars:
#   project_name  (default: myproject)
#   part          (default: xcku115-flvb2104-2-i)
#   clock_period  (default: 5.0)
#   strategy      (default: Latency)
#   tech          (default: fpga)
#   io_type       (default: io_stream)
#   granularity   (default: name)
#   default_precision (default: ac_fixed<16,8,true>)
#   max_precision (default: ac_fixed<16,8,true>)
#   num_samples   (default: 8)
#   min_fifo_depth (default: 16; clamps generated stream FIFO depth pragmas)
#   run_csim      (default: 0)
#   run_cosim     (default: 0)
#   run_vsynth    (default: 0)
#   auto_exit     (default: 1, exit Catapult after flow finishes)

set sfd [file dirname [info script]]

if {![info exists model_path]}   { set model_path   "[pwd]/keras_model.h5" }
if {![info exists out_dir]}      { set out_dir      "[pwd]/catapult_native" }
if {![info exists project_name]} { set project_name "myproject" }
if {![info exists reuse_factor]} { set reuse_factor 16 }
if {![info exists part]}         { set part         "xcku115-flvb2104-2-i" }
if {![info exists clock_period]} { set clock_period 5.0 }
if {![info exists strategy]}     { set strategy     "Latency" }
if {![info exists tech]}         { set tech         "fpga" }
if {![info exists io_type]}      { set io_type      "io_stream" }
if {![info exists granularity]}  { set granularity  "name" }
if {![info exists default_precision]} { set default_precision "ac_fixed<16,8,true>" }
if {![info exists max_precision]} { set max_precision "ac_fixed<16,8,true>" }
if {![info exists num_samples]}  { set num_samples  8 }
if {![info exists run_synth]}    { set run_synth    1 }
if {![info exists run_csim]}     { set run_csim     0 }
if {![info exists run_cosim]}    { set run_cosim    0 }
if {![info exists run_vsynth]}   { set run_vsynth   0 }
if {![info exists run_reset]}    { set run_reset    "auto" }
if {![info exists min_fifo_depth]} { set min_fifo_depth 16 }
if {![info exists auto_exit]}    { set auto_exit    1 }

if {![file exists $model_path]} {
  logfile message "Model file not found: $model_path\n" error
}

logfile message "Catapult flow: model_path=$model_path out_dir=$out_dir reuse_factor=$reuse_factor\n" info

options defaults
project new

flow package require /HLS4ML
flow run /HLS4ML/create_venv

# /HLS4ML/gen_hls4ml ultimately runs a bash command. Precision strings like
# ac_fixed<16,8,true> must be quoted so '<' and '>' are not parsed as
# redirection operators by the shell.
set default_precision_arg [format "'%s'" $default_precision]
set max_precision_arg [format "'%s'" $max_precision]

flow run /HLS4ML/gen_hls4ml $sfd/catapult_from_h5_model.py \
  --model_path $model_path \
  --output_dir $out_dir \
  --project_name $project_name \
  --reuse_factor $reuse_factor \
  --part $part \
  --clock_period $clock_period \
  --strategy $strategy \
  --tech $tech \
  --io_type $io_type \
  --granularity $granularity \
  --default_precision $default_precision_arg \
  --max_precision $max_precision_arg \
  --num_samples $num_samples

if {![file exists $out_dir]} {
  logfile message "Expected output directory missing: $out_dir\n" error
}

# Work around Catapult FIFO library mapping failures seen with fifo_depth="1"
# in generated io_stream channel pragmas. Clamp to a safer minimum depth.
set firmware_cpp [file join $out_dir "firmware" "myproject.cpp"]
if {[file exists $firmware_cpp]} {
  set fp [open $firmware_cpp "r"]
  set cpp_text [read $fp]
  close $fp

  set replacement [format {fifo_depth="%s"} $min_fifo_depth]
  set replaced_count [regsub -all {fifo_depth="1"} $cpp_text $replacement cpp_text]
  if {$replaced_count > 0} {
    set fpw [open $firmware_cpp "w"]
    puts -nonewline $fpw $cpp_text
    close $fpw
    logfile message "Patched firmware/myproject.cpp FIFO depth pragmas: replaced $replaced_count entries with depth=$min_fifo_depth\n" warning
  }
}

set_working_dir $out_dir

# build_prj.tcl interprets reset=1 as "project load Catapult.ccs; go new".
# On first run Catapult.ccs does not exist yet, so default to reset=0.
if {$run_reset eq "auto"} {
  set reset_flag [expr {[file exists [file join $out_dir "Catapult.ccs"]] ? 1 : 0}]
} elseif {[string is integer -strict $run_reset]} {
  set reset_flag [expr {$run_reset != 0}]
} else {
  set reset_flag [expr {[string is true -strict $run_reset] ? 1 : 0}]
}

if {$run_synth} {
  set synth_flag 1
} else {
  set synth_flag 0
}

logfile message "Catapult flow: using reset=$reset_flag synth=$synth_flag\n" info

set ::argv [list \
  "reset=$reset_flag" \
  "csim=$run_csim" \
  "synth=$synth_flag" \
  "cosim=$run_cosim" \
  "vsynth=$run_vsynth" \
]

dofile build_prj.tcl

if {$auto_exit} {
  exit
}
