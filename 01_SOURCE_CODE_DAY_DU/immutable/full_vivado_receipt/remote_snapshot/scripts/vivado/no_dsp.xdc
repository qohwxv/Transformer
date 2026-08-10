# Production NPU policy: arithmetic must map to LUT/carry logic, never DSP.
# MAX_DSP=0 is also set on synth_1 by configure_project.tcl. This XDC adds
# USE_DSP=NO to every non-primitive ViT RTL instance seen by synthesis.

set_property USE_DSP NO \
    [get_cells -quiet -hierarchical \
        -filter {IS_PRIMITIVE == 0 && REF_NAME =~ vit_*}]
