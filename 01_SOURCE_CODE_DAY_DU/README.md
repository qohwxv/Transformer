<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/117bccc1-8057-40a6-aa8c-56185b1e9e86" />
<img width="1101" height="594" alt="image" src="https://github.com/user-attachments/assets/64b7b54d-ca76-4b8c-aaca-58a02985d29b" />

┌──────────────────────────────────────────────┐
│ TOP / AXI SHELL                              │
│                                              │
│ vit_phase_e_axi_bd_wrapper.v                 │
│ vit_phase_e_axi_wrapper.sv                   │
│ vit_phase_e_axi_mem_adapter.sv               │
│ vit_axi_lite_control_regs.sv                 │
└───────────────────────┬──────────────────────┘
                        │
┌───────────────────────▼──────────────────────┐
│ NPU CORE                                     │
│                                              │
│ vit_phase_e_npu.sv                           │
│ vit_phase_e_engine_top.sv                    │
│ vit_phase_e_engine_dispatch.sv               │
│ vit_phase_e_command_controller.sv            │
│ vit_phase_e_memory_frontend.sv               │
│ read/write_address_router                    │
│ gemm_memory_address_context                  │
└───────────────────────┬──────────────────────┘
                        │
┌───────────────────────▼──────────────────────┐
│ SEQUENCER                                    │
│                                              │
│ vit_phase_e_sequencer.sv                     │
│                                              │
│ 249-command execution schedule               │
└──────────┬───────────────┬───────────────────┘
           │               │
           ▼               ▼
┌─────────────────┐  ┌────────────────────────┐
│ GEMM            │  │ NON-GEMM               │
│                 │  │                        │
│ controller      │  │ Vector                 │
│ operand router  │  │ Layout                 │
│ panel cache     │  │ LayerNorm              │
│ bias cache      │  │ Softmax                │
│ PE array        │  │ GELU                   │
│ scheduler       │  │ Argmax                 │
│ accumulator     │  │                        │
└─────────┬───────┘  └───────────┬────────────┘
          │                      │
          └──────────┬───────────┘
                     ▼
              Memory Frontend
                     │
              AXI Mem Adapter
                     │
                128-bit M_AXI
                     │
               SmartConnect
                     │
                  PS DDR
