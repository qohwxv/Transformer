<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/117bccc1-8057-40a6-aa8c-56185b1e9e86" />
<img width="1101" height="594" alt="image" src="https://github.com/user-attachments/assets/64b7b54d-ca76-4b8c-aaca-58a02985d29b" />


1. rtl/top/vit_phase_e_axi_bd_wrapper.v
              ↓
2. rtl/axi/vit_phase_e_axi_wrapper.sv
              ↓
3. rtl/axi/control/vit_axi_lite_control_regs.sv
              ↓
4. rtl/core/vit_phase_e_npu.sv
              ↓
5. rtl/core/vit_phase_e_engine_top.sv
              ↓
6. rtl/core/vit_phase_e_command_controller.sv
              ↓
7. rtl/control/vit_phase_e_sequencer.sv
              ↓
8. rtl/core/vit_phase_e_memory_frontend.sv
              ↓
9. rtl/axi/memory/vit_phase_e_axi_mem_adapter.sv
              ↓
10. rtl/blocks/gemm/vit_gemm_controller.sv
              ↓
11. vit_gemm_activation_panel_cache.sv
              ↓
12. vit_gemm_fp16_parallel_scheduler.sv
