# Catapult flow script to synthesize an existing Keras/QKeras model (.h5)
# via the /HLS4ML flow package.
#
# Usage inside catapult-shell:
#   set model_path /abs/path/to/keras_model.h5
#   set out_dir /abs/path/to/catapult_native
#   set cfg_json /abs/path/to/dataflow_config.json
#   dofile /abs/path/to/util/catapult_hls4ml_flow.tcl
#
# Optional vars:
#   run_synth     (default: 1)
#   run_csim      (default: 0)
#   run_cosim     (default: 0)
#   run_vsynth    (default: 0)
#   run_reset     (default: auto)
#   auto_exit     (default: 1)

set sfd [file dirname [info script]]

if {![info exists model_path]}   { set model_path   "[pwd]/keras_model.h5" }
if {![info exists out_dir]}      { set out_dir      "[pwd]/catapult_native" }
if {![info exists cfg_json]}     { set cfg_json     "" }

if {![info exists run_synth]}    { set run_synth    1 }
if {![info exists run_csim]}     { set run_csim     0 }
if {![info exists run_cosim]}    { set run_cosim    0 }
if {![info exists run_vsynth]}   { set run_vsynth   0 }
if {![info exists run_reset]}    { set run_reset    "auto" }
if {![info exists auto_exit]}    { set auto_exit    1 }

if {![file exists $model_path]} {
  logfile message "Model file not found: $model_path\n" error
}

logfile message "Catapult flow: model_path=$model_path out_dir=$out_dir cfg_json=$cfg_json\n" info

options defaults
project new

flow package require /HLS4ML
flow run /HLS4ML/create_venv

# The python script reads CatapultDataflowConfig JSON and calls config_for_dataflow with ALL knobs.
set cmd [list \
  $sfd/catapult_from_h5_model.py \
  --model_path $model_path \
  --output_dir $out_dir \
]

if {$cfg_json ne ""} { lappend cmd --config_json $cfg_json }

flow run /HLS4ML/gen_hls4ml {*}$cmd

if {![file exists $out_dir]} {
  logfile message "Expected output directory missing: $out_dir\n" error
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

set ::argv [list \
  "reset=$reset_flag" \
  "csim=$run_csim" \
  "synth=[expr {$run_synth ? 1 : 0}]" \
  "cosim=$run_cosim" \
  "vsynth=$run_vsynth" \
]

dofile build_prj.tcl

if {$auto_exit} {
  exit
}