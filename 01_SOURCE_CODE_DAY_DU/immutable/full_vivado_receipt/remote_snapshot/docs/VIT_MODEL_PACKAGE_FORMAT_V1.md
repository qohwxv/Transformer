# Đặc tả gói model ViT binary – phiên bản 1

## 1. Mục đích và phạm vi

Tài liệu này là đặc tả nhị phân chuẩn cho ba file được tạo bởi
`tools/pack_vit_assets.py`:

- `vit_model.bin`: toàn bộ 200 tensor tham số của ViT-Base/16.
- `vit_model_table.bin`: header mô tả gói model và 200 entry mô tả tensor.
- `prepared_input.bin`: input đã preprocess, dùng trực tiếp cho datapath.

Các hằng số và thứ tự tensor chuẩn được định nghĩa tại
`tools/vit_model_schema.py`. Nếu tài liệu và mã nguồn không đồng nhất, cần dừng
quy trình đóng gói và sửa cả hai trong cùng một thay đổi phiên bản; không được
âm thầm thay đổi layout của phiên bản 1.

Định dạng này không chứa thuật toán ViT, command ISA hay scratch memory. Nó chỉ
quy định cách SW và HW cùng nhìn thấy model/input trong DDR.

## 2. Quy ước bắt buộc

### 2.1. Kiểu dữ liệu và byte order

- Một data word luôn rộng 32 bit.
- Nội dung word là **raw bit pattern IEEE-754 binary32 (FP32)**.
- Tất cả số nguyên nhiều byte trong `vit_model_table.bin` dùng
  **little-endian**.
- Mỗi FP32 word trong `vit_model.bin` và `prepared_input.bin` cũng được ghi
  little-endian.
- Packer không parse số thực, không làm tròn, không đổi precision và không
  transpose dữ liệu. Nó chuyển trực tiếp mỗi chuỗi hex 32-bit thành bốn byte.

Ví dụ:

| Word trong file `.hex` | Bốn byte trong file `.bin`, từ địa chỉ thấp đến cao |
|---:|---|
| `3F800000` | `00 00 80 3F` |
| `3C0096DB` | `DB 96 00 3C` |
| `3EDEDEDF` | `DF DE DE 3E` |

### 2.2. Đơn vị địa chỉ

Mọi `word_offset` trong model table và mọi parameter offset đưa vào descriptor
đều tính theo **FP32 word**, không phải byte.

Phép ánh xạ bắt buộc sang địa chỉ AXI byte là:

```text
parameter_byte_address =
    MODEL_BASE_PHYS + (uint64(word_offset) << 2)
```

Tương tự:

```text
input_byte_address   = INPUT_BASE_PHYS   + (uint64(input_word_offset)   << 2)
scratch_byte_address = SCRATCH_BASE_PHYS + (uint64(scratch_word_offset) << 2)
```

Phép dịch phải được thực hiện sau khi mở rộng thành 64 bit. Không nhân/dịch
trong miền 32 bit rồi mới cast, vì cách đó có thể overflow khi mở rộng model
hoặc đổi board.

`MODEL_BASE_PHYS` phải được căn ít nhất 64 byte. Khi đó mọi tensor có
`word_offset` chia hết cho 16 cũng được căn 64 byte ở địa chỉ vật lý.

### 2.3. Khoảng địa chỉ

Tất cả khoảng dữ liệu trong tài liệu dùng quy ước nửa mở:

```text
[start, end_exclusive)
```

Word cuối của tensor có địa chỉ:

```text
word_offset + word_count - 1
```

Byte kết thúc không thuộc tensor:

```text
(word_offset + word_count) << 2
```

## 3. Tổng quan ba file

| File | Header nội bộ | Số word dữ liệu | Kích thước bắt buộc | Chức năng |
|---|---:|---:|---:|---|
| `vit_model.bin` | Không | 86.567.664 word lưu trữ | 346.270.656 byte (`0x14A3ABC0`) | 86.567.656 word tensor và 8 word padding |
| `vit_model_table.bin` | 128 byte | Không áp dụng | 12.928 byte (`0x3280`) | Header và 200 entry |
| `prepared_input.bin` | Không | 150.528 word | 602.112 byte (`0x93000`, 588 KiB) | Input đã preprocess |

`vit_model.bin` có kích thước xấp xỉ 330,23 MiB. `vit_model_table.bin` và
`prepared_input.bin` là hai file độc lập; chúng không được nối vào đầu hoặc cuối
`vit_model.bin`.

Hai file JSON do packer sinh thêm không phải một phần của binary ABI:

- `vit_model_table.json`: bản diễn giải có filename, role, offset và hash để
  debug.
- `hash_manifest.json`: CRC32/SHA-256 của ba file binary.

## 4. Định dạng `vit_model.bin`

### 4.1. Quy tắc chung

`vit_model.bin` là payload thuần, không có magic và không có header. Tensor được
ghi tuần tự theo canonical order tại mục 7.

Trước mỗi tensor, packer tính:

```text
aligned_word_offset = align_up(current_word_offset, 16)
padding_words       = aligned_word_offset - current_word_offset
```

Vì 16 FP32 word bằng 64 byte, địa chỉ đầu mọi tensor được căn 64 byte. Padding
phải chứa toàn byte zero và không thuộc CRC32 riêng của tensor.

Trong model v1 hiện tại:

- Tổng word nguồn: `86.567.656` (`0x0528EAE8`).
- Tổng padding: `8` word, tức 32 byte.
- Tổng word lưu trữ: `86.567.664` (`0x0528EAF0`).
- Kích thước file: `346.270.656` byte (`0x14A3ABC0`).
- Chỉ có một đoạn padding: word offset
  `[0x001716E8, 0x001716F0)`.
- Đoạn padding nằm sau `classifier_bias_base` và trước
  `encoder_layer_00_ln_before_gamma_f32.hex`.

Không có padding ở cuối file. End-exclusive word offset của model là
`0x0528EAF0`.

### 4.2. Giữ nguyên thứ tự word

Với mỗi file `.hex`, word thứ `i` trở thành word thứ `i` của tensor trong
binary:

```text
model_word[word_offset + i] = uint32(hex_line[i])
```

Riêng byte order trong DDR là little-endian như mục 2.1. Packer không đổi
`[K,N]` thành `[N,K]`; các file có hậu tố `_weight_B_` đã mang layout B dùng cho
GEMM theo contract hiện tại.

## 5. Định dạng `vit_model_table.bin`

### 5.1. Layout cấp file

```text
byte 0x0000 .. 0x007F : table header, 128 byte
byte 0x0080 .. 0x327F : 200 tensor entries, mỗi entry 64 byte
byte 0x3280           : end exclusive
```

Entry có `tensor_id = i` bắt đầu tại:

```text
entry_byte_offset = 0x80 + i * 0x40
```

File không chứa chuỗi filename hay role. Nó chỉ chứa `tensor_id` và hash
FNV-1a-64 của basename. Tên đầy đủ và role có trong JSON sidecar.

### 5.2. Header 128 byte

Header được pack bằng format Python:

```text
<8sHH7I5Q4I32s
```

Trong đó `<` có nghĩa là little-endian, không thêm native padding.

| Byte offset | Kích thước | Kiểu | Field | Giá trị/ý nghĩa phiên bản 1 |
|---:|---:|---|---|---|
| `0x00` | 8 | `u8[8]` | `magic` | ASCII `VITMTBL` và byte `00`: `56 49 54 4D 54 42 4C 00` |
| `0x08` | 2 | `u16` | `version_major` | `1` |
| `0x0A` | 2 | `u16` | `version_minor` | `0` |
| `0x0C` | 4 | `u32` | `header_bytes` | `128` (`0x80`) |
| `0x10` | 4 | `u32` | `endian` | `1` = little-endian |
| `0x14` | 4 | `u32` | `dtype` | `1` = raw IEEE-754 FP32 bits |
| `0x18` | 4 | `u32` | `entry_count` | `200` |
| `0x1C` | 4 | `u32` | `entry_bytes` | `64` (`0x40`) |
| `0x20` | 4 | `u32` | `alignment_bytes` | `64` (`0x40`) |
| `0x24` | 4 | `u32` | `table_flags` | `0x0000001F` |
| `0x28` | 8 | `u64` | `entries_offset` | `128` (`0x80`) |
| `0x30` | 8 | `u64` | `table_bytes` | `12.928` (`0x3280`) |
| `0x38` | 8 | `u64` | `source_words` | `86.567.656` (`0x0528EAE8`) |
| `0x40` | 8 | `u64` | `storage_words` | `86.567.664` (`0x0528EAF0`) |
| `0x48` | 8 | `u64` | `model_bytes` | `346.270.656` (`0x14A3ABC0`) |
| `0x50` | 4 | `u32` | `model_crc32` | CRC32 toàn bộ `vit_model.bin`, gồm padding |
| `0x54` | 4 | `u32` | `entries_crc32` | CRC32 của đúng 12.800 byte entry |
| `0x58` | 4 | `u32` | `header_crc32` | CRC32 header theo quy tắc mục 9 |
| `0x5C` | 4 | `u32` | `crc_algorithm` | `1` = CRC-32/ISO-HDLC, tương thích `zlib.crc32` |
| `0x60` | 32 | `u8[32]` | `model_sha256` | SHA-256 binary của toàn bộ `vit_model.bin`, gồm padding |

`table_flags` là giá trị profile cố định của table v1. Mã nguồn hiện tại chưa
khai báo ý nghĩa độc lập cho từng bit. Consumer phải kiểm tra giá trị/profile
được hỗ trợ, không được tự suy diễn semantics riêng cho bit 0..4.

### 5.3. Tensor entry 64 byte

Mỗi entry được pack bằng:

```text
<IHBBQQQIIIIIIII
```

hay tương đương:

```text
<IHBBQQQ + 8 × u32
```

| Offset trong entry | Kích thước | Kiểu | Field | Ý nghĩa |
|---:|---:|---|---|---|
| `0x00` | 4 | `u32` | `tensor_id` | ID canonical từ 0 đến 199 |
| `0x04` | 2 | `u16` | `group` | `0` = global, `1` = encoder |
| `0x06` | 1 | `u8` | `layer` | Global dùng `0xFF`; encoder dùng 0..11 |
| `0x07` | 1 | `u8` | `slot` | Global dùng 0..7; mỗi layer dùng 0..15 |
| `0x08` | 8 | `u64` | `name_hash` | FNV-1a-64 của basename UTF-8 |
| `0x10` | 8 | `u64` | `word_offset` | Offset tensor trong `vit_model.bin`, đơn vị FP32 word |
| `0x18` | 8 | `u64` | `word_count` | Số FP32 word của tensor, không gồm padding |
| `0x20` | 4 | `u32` | `rank` | Số chiều hợp lệ trong `dim[0..3]`, hiện là 1 hoặc 2 |
| `0x24` | 4 | `u32` | `layout` | Layout ID, xem mục 5.4 |
| `0x28` | 4 | `u32` | `dim0` | Chiều 0 |
| `0x2C` | 4 | `u32` | `dim1` | Chiều 1 hoặc 0 nếu rank 1 |
| `0x30` | 4 | `u32` | `dim2` | 0 trong model v1 |
| `0x34` | 4 | `u32` | `dim3` | 0 trong model v1 |
| `0x38` | 4 | `u32` | `tensor_crc32` | CRC32 payload riêng của tensor, không gồm padding |
| `0x3C` | 4 | `u32` | `tensor_flags` | Thuộc tính tensor, xem mục 5.5 |

Không nên cast trực tiếp buffer vào C/C++ struct có alignment mặc định. SW nên
đọc little-endian theo offset, hoặc dùng packed struct kèm `static_assert`:

```text
sizeof(header) == 128
sizeof(entry)  == 64
```

### 5.4. Layout ID

| ID | Tên | Contract |
|---:|---|---|
| `1` | `VECTOR` | Vector một chiều |
| `2` | `ROW_MAJOR` | Tensor hai chiều theo thứ tự row-major |
| `3` | `GEMM_B_KN` | Ma trận B đã bố trí theo chiều `[K,N]`; packer giữ nguyên thứ tự nguồn |

### 5.5. Tensor flags

| Bit | Mask | Tên | Ý nghĩa |
|---:|---:|---|---|
| 0 | `0x00000001` | `WEIGHT_B` | Tensor là GEMM B weight |
| 1 | `0x00000002` | `BIAS` | Bias |
| 2 | `0x00000004` | `GAMMA` | LayerNorm gamma |
| 3 | `0x00000008` | `BETA` | LayerNorm beta |
| 4 | `0x00000010` | `EMBEDDING` | Thuộc embedding |
| 5 | `0x00000020` | `FINAL` | Thuộc post-encoder/final stage |
| 6 | `0x00000040` | `ENCODER` | Thuộc một encoder layer |

Một entry có thể bật nhiều bit. Ví dụ embedding patch weight có
`WEIGHT_B | EMBEDDING = 0x11`; Q weight của encoder có
`WEIGHT_B | ENCODER = 0x41`.

### 5.6. FNV-1a-64 filename hash

`name_hash` được tính trên **basename chính xác**, encode UTF-8, không gồm đường
dẫn:

```text
hash = 0xCBF29CE484222325
for byte in filename_utf8:
    hash = hash XOR byte
    hash = (hash * 0x100000001B3) mod 2^64
```

Hash hỗ trợ phát hiện nhầm tên/schema; `tensor_id`, `group`, `layer` và `slot`
vẫn là khóa định vị canonical. Không dùng hash như cơ chế bảo mật.

## 6. Định dạng `prepared_input.bin`

`prepared_input.bin` là payload thuần, không có header và không có padding:

```text
word_count = 150.528
byte_count = 602.112 = 0x93000
```

Thứ tự word giống hoàn toàn
`preprocessed/embedding_input_patch_A_f32.hex`. Packer hiện chỉ quy định chặt
số word và bit pattern; shape/ngữ nghĩa tensor input nằm trong contract của
datapath, không được suy ra từ một header trong file vì file này không có
header.

Địa chỉ input dùng `INPUT_BASE_PHYS`, độc lập với `MODEL_BASE_PHYS`. Input
offset trong descriptor cũng dùng đơn vị FP32 word và phải đổi sang byte bằng
`offset << 2`.

## 7. Canonical order của 200 tensor

### 7.1. Công thức ID

```text
global tensor:  tensor_id = slot                       // 0..7
encoder tensor: tensor_id = 8 + layer * 16 + slot     // 8..199
```

Với encoder:

```text
layer = 0..11
slot  = 0..15
```

Tên file encoder được tạo theo:

```text
encoder_layer_{layer:02d}_{stem}_f32.hex
```

Do đó:

- Layer 0 dùng ID 8..23.
- Layer 1 dùng ID 24..39.
- ...
- Layer 11 dùng ID 184..199.

### 7.2. Tám tensor global

| ID/slot | Role | Basename | Shape | Layout | Word offset | Byte offset | Word count |
|---:|---|---|---:|---|---:|---:|---:|
| 0 | `patch_weight_base` | `embedding_patch_weight_B_f32.hex` | `[768,768]` | `GEMM_B_KN` | `0x00000000` | `0x00000000` | 589.824 |
| 1 | `patch_bias_base` | `embedding_patch_bias_f32.hex` | `[768]` | `VECTOR` | `0x00090000` | `0x00240000` | 768 |
| 2 | `cls_base` | `embedding_cls_token_f32.hex` | `[768]` | `VECTOR` | `0x00090300` | `0x00240C00` | 768 |
| 3 | `position_base` | `embedding_position_f32.hex` | `[197,768]` | `ROW_MAJOR` | `0x00090600` | `0x00241800` | 151.296 |
| 4 | `final_ln_gamma_base` | `post_encoder_final_ln_gamma_f32.hex` | `[768]` | `VECTOR` | `0x000B5500` | `0x002D5400` | 768 |
| 5 | `final_ln_beta_base` | `post_encoder_final_ln_beta_f32.hex` | `[768]` | `VECTOR` | `0x000B5800` | `0x002D6000` | 768 |
| 6 | `classifier_weight_base` | `post_encoder_classifier_weight_B_f32.hex` | `[768,1000]` | `GEMM_B_KN` | `0x000B5B00` | `0x002D6C00` | 768.000 |
| 7 | `classifier_bias_base` | `post_encoder_classifier_bias_f32.hex` | `[1000]` | `VECTOR` | `0x00171300` | `0x005C4C00` | 1.000 |

Classifier bias kết thúc tại word offset `0x001716E8`. Tám zero word kế tiếp
làm cho encoder layer 0 bắt đầu tại word offset `0x001716F0`, tương ứng byte
offset `0x005C5BC0`.

### 7.3. Mười sáu tensor trong mỗi encoder layer

Mỗi layer có đúng cùng layout tương đối và chiếm:

```text
LAYER_SPAN_WORDS = 0x006C2700 = 7.087.872 word
LAYER_SPAN_BYTES = 0x01B09C00 = 28.351.488 byte
```

Đặt `layer_base_word` theo mục 7.4. Offset tuyệt đối của slot là:

```text
absolute_word_offset = layer_base_word + relative_word_offset
```

| Slot | Role | Filename stem | Shape | Layout | Relative word offset | Word count |
|---:|---|---|---:|---|---:|---:|
| 0 | `ln1_gamma_base` | `ln_before_gamma` | `[768]` | `VECTOR` | `0x00000000` | 768 |
| 1 | `ln1_beta_base` | `ln_before_beta` | `[768]` | `VECTOR` | `0x00000300` | 768 |
| 2 | `q_weight_base` | `q_weight_B` | `[768,768]` | `GEMM_B_KN` | `0x00000600` | 589.824 |
| 3 | `q_bias_base` | `q_bias` | `[768]` | `VECTOR` | `0x00090600` | 768 |
| 4 | `k_weight_base` | `k_weight_B` | `[768,768]` | `GEMM_B_KN` | `0x00090900` | 589.824 |
| 5 | `k_bias_base` | `k_bias` | `[768]` | `VECTOR` | `0x00120900` | 768 |
| 6 | `v_weight_base` | `v_weight_B` | `[768,768]` | `GEMM_B_KN` | `0x00120C00` | 589.824 |
| 7 | `v_bias_base` | `v_bias` | `[768]` | `VECTOR` | `0x001B0C00` | 768 |
| 8 | `o_weight_base` | `o_weight_B` | `[768,768]` | `GEMM_B_KN` | `0x001B0F00` | 589.824 |
| 9 | `o_bias_base` | `o_bias` | `[768]` | `VECTOR` | `0x00240F00` | 768 |
| 10 | `ln2_gamma_base` | `ln_after_gamma` | `[768]` | `VECTOR` | `0x00241200` | 768 |
| 11 | `ln2_beta_base` | `ln_after_beta` | `[768]` | `VECTOR` | `0x00241500` | 768 |
| 12 | `fc1_weight_base` | `fc1_weight_B` | `[768,3072]` | `GEMM_B_KN` | `0x00241800` | 2.359.296 |
| 13 | `fc1_bias_base` | `fc1_bias` | `[3072]` | `VECTOR` | `0x00481800` | 3.072 |
| 14 | `fc2_weight_base` | `fc2_weight_B` | `[3072,768]` | `GEMM_B_KN` | `0x00482400` | 2.359.296 |
| 15 | `fc2_bias_base` | `fc2_bias` | `[768]` | `VECTOR` | `0x006C2400` | 768 |

Mỗi layer kết thúc tại:

```text
layer_base_word + 0x006C2700
```

Không có padding bên trong hoặc giữa các encoder layer của model v1 vì mọi
word count trong layer đã là bội số của 16.

### 7.4. Base tuyệt đối của 12 encoder layer

| Layer | ID đầu..cuối | Base word offset | Base byte offset |
|---:|---:|---:|---:|
| 0 | 8..23 | `0x001716F0` | `0x005C5BC0` |
| 1 | 24..39 | `0x00833DF0` | `0x020CF7C0` |
| 2 | 40..55 | `0x00EF64F0` | `0x03BD93C0` |
| 3 | 56..71 | `0x015B8BF0` | `0x056E2FC0` |
| 4 | 72..87 | `0x01C7B2F0` | `0x071ECBC0` |
| 5 | 88..103 | `0x0233D9F0` | `0x08CF67C0` |
| 6 | 104..119 | `0x02A000F0` | `0x0A8003C0` |
| 7 | 120..135 | `0x030C27F0` | `0x0C309FC0` |
| 8 | 136..151 | `0x03784EF0` | `0x0DE13BC0` |
| 9 | 152..167 | `0x03E475F0` | `0x0F91D7C0` |
| 10 | 168..183 | `0x04509CF0` | `0x114273C0` |
| 11 | 184..199 | `0x04BCC3F0` | `0x12F30FC0` |

Base cũng có thể tính bằng:

```text
layer_base_word(layer) =
    0x001716F0 + layer * 0x006C2700
```

Layer 11 kết thúc đúng tại end-exclusive word offset của model:
`0x0528EAF0`.

## 8. Quy tắc nguồn `.hex` và tính xác định

Packer chấp nhận model v1 chỉ khi:

- Thư mục `parameters/` chứa đúng 200 file canonical.
- Thiếu file hoặc có thêm bất kỳ file thường nào đều là lỗi.
- Mỗi dòng có đúng 8 ký tự hex uppercase và một ký tự LF.
- Không chấp nhận lowercase, tiền tố `0x`, dấu cách, dòng trống hoặc CRLF.
- Số dòng của từng file phải khớp `word_count` trong schema.
- Input phải có đúng 150.528 dòng với cùng format.

Khi các điều kiện trên giống nhau, output binary, CRC và SHA phải giống nhau
bit-for-bit. Packer ghi ra file `.tmp`, flush/fsync rồi mới atomic replace file
đích; output cũ không bị thay bằng file đóng gói dở khi phát sinh lỗi.

## 9. CRC32 và SHA-256

### 9.1. Thuật toán CRC

Algorithm ID `1` là CRC-32/ISO-HDLC và phải cho cùng kết quả với:

```python
zlib.crc32(data) & 0xFFFFFFFF
```

Khi xử lý theo chunk, truyền CRC của chunk trước làm tham số thứ hai cho
`zlib.crc32`. Giá trị lưu trên file là `u32` little-endian.

### 9.2. Phạm vi bảo vệ

| Giá trị | Phạm vi byte |
|---|---|
| `tensor_crc32` | Chỉ payload của tensor tương ứng; không gồm padding trước/sau |
| `model_crc32` | Toàn bộ `vit_model.bin`, gồm 8 zero padding word |
| `entries_crc32` | `vit_model_table.bin[0x80:0x3280]` |
| `header_crc32` | 128 byte header với field `header_crc32` tạm đặt bằng zero |
| Whole-table CRC trong manifest | Toàn bộ `vit_model_table.bin` sau khi điền header CRC |
| Input CRC trong manifest | Toàn bộ `prepared_input.bin` |
| `model_sha256` | Toàn bộ `vit_model.bin`, gồm padding |

Để kiểm tra `header_crc32`:

1. Đọc đúng 128 byte header.
2. Lưu giá trị tại byte `0x58..0x5B`.
3. Gán bốn byte `0x58..0x5B` thành zero.
4. Tính CRC32 trên 128 byte đã sửa.
5. So sánh với giá trị đã lưu.

SHA-256 của table và input không nằm trong table binary; chúng được lưu trong
`hash_manifest.json`. Whole-table CRC cũng chỉ có trong JSON/manifest.

## 10. Trình tự validate phía software

Trước khi cho PL đọc model, A53 nên thực hiện theo thứ tự:

1. Kiểm tra kích thước `vit_model_table.bin` tối thiểu 128 byte.
2. Kiểm tra `magic`, major/minor version, endian và dtype.
3. Kiểm tra `header_bytes == 128`, `entry_bytes == 64`,
   `entry_count == 200`.
4. Kiểm tra `entries_offset == 128` và
   `table_bytes == 128 + 200 * 64 == 12.928`.
5. Kiểm tra kích thước file table bằng đúng `table_bytes`.
6. Recompute và kiểm tra `header_crc32`.
7. Recompute và kiểm tra `entries_crc32`.
8. Kiểm tra kích thước `vit_model.bin == model_bytes`.
9. Kiểm tra `source_words`, `storage_words`, `model_bytes` nhất quán.
10. Kiểm tra `model_crc32`; khi boot production nên kiểm tra thêm
    `model_sha256`.
11. Với mỗi entry, kiểm tra ID/group/layer/slot canonical, rank hợp lệ,
    `word_offset % 16 == 0`, word range không vượt `storage_words`, và không
    overlap tensor khác.
12. Recompute `tensor_crc32` nếu cần chẩn đoán tensor cụ thể.
13. Kiểm tra `prepared_input.bin` có đúng 602.112 byte và hash khớp manifest.

Nếu bất kỳ bước nào lỗi, SW không được ghi `START`/`DOORBELL` cho accelerator.
Nên trả error code phân biệt lỗi table, model, input và address allocation.

## 11. Trình tự nạp vào DDR trên Genesys ZU-5EV

### 11.1. Phân vùng runtime

A53/allocator phải cấp các vùng vật lý không overlap:

```text
MODEL_BASE_PHYS   : ít nhất 346.270.656 byte, alignment >= 64 byte
INPUT_BASE_PHYS   : ít nhất     602.112 byte, alignment >= 64 byte khuyến nghị
SCRATCH_BASE_PHYS : kích thước theo scratch map, alignment >= 64 byte khuyến nghị
```

Table có thể được giữ trong RAM của A53 để validate và dùng populate parameter
table RAM trong PL. Nếu một phiên bản HW sau này DMA trực tiếp table, cấp thêm
`TABLE_BASE_PHYS` với ít nhất 12.928 byte.

### 11.2. Luồng nạp

```text
SD/network/filesystem
        |
        +--> read + validate vit_model_table.bin
        |
        +--> allocate MODEL/INPUT/SCRATCH regions
        |
        +--> copy vit_model.bin      -> MODEL_BASE_PHYS
        +--> copy prepared_input.bin -> INPUT_BASE_PHYS
        |
        +--> flush CPU cache for ranges PL will read
        |
        +--> program physical bases/sizes
        +--> program 8 global + 12×16 layer word offsets
        |
        +--> START/DOORBELL
        |
        +--> wait IRQ
        |
        +--> invalidate CPU cache for ranges PL wrote
        +--> read result/status/counters
```

Với AXI port không cache-coherent, flush trước khi PL đọc và invalidate sau khi
PL ghi là bắt buộc. Với coherent port, software vẫn phải theo đúng API
coherency của platform; không được giả định cache tự đồng bộ chỉ vì địa chỉ là
DDR.

### 11.3. Parameter table trong PL

Model table chứa offset, không chứa địa chỉ vật lý cuối. Cách triển khai khuyến
nghị:

- A53 validate table binary.
- A53 ghi 8 global offsets và `12 × 16` layer offsets vào register/table RAM
  của PL.
- Sequencer chọn offset theo global role hoặc `(layer, slot)`.
- Address mapper duy nhất tạo:
  `MODEL_BASE_PHYS + (word_offset << 2)`.

Không cộng `MODEL_BASE_PHYS` ở nhiều tầng. Descriptor và parameter table nên
giữ word offset; chỉ AXI address mapper chuyển sang byte address. Quy tắc này
ngăn lỗi nhân bốn hai lần hoặc quên nhân bốn.

### 11.4. Kiểm tra smoke trước full inference

Sau khi copy vào DDR và trước khi chạy engine:

- Đọc word đầu của model tại `MODEL_BASE_PHYS + 0`.
- Giá trị kỳ vọng của package nguồn hiện tại là `0x3C0096DB`; trên bus byte
  little-endian phải quan sát `DB 96 00 3C`.
- Đọc word đầu input tại `INPUT_BASE_PHYS + 0`.
- Giá trị kỳ vọng của input hiện tại là `0x3EDEDEDF`; byte phải là
  `DF DE DE 3E`.
- Đọc word cuối input tại
  `INPUT_BASE_PHYS + ((150528 - 1) << 2)`; giá trị kỳ vọng hiện tại là
  `0x3F800000`.
- Kiểm tra tám padding word tại model word offset
  `0x001716E8..0x001716EF` đều bằng zero.

Các giá trị smoke trên là checkpoint của asset hiện tại, không thay thế
CRC/SHA. Nếu thay model/input hợp lệ trong tương lai, hash manifest và checkpoint
phải được version hóa lại.

## 12. Sinh package

Từ root của repository:

```bash
.venv/bin/python tools/pack_vit_assets.py
```

Đường dẫn mặc định:

```text
parameters/                                      # 200 source tensor files
preprocessed/embedding_input_patch_A_f32.hex     # source input
build/model_package/v1/                          # output
```

Có thể chỉ định rõ:

```bash
.venv/bin/python tools/pack_vit_assets.py \
  --parameters parameters \
  --input-hex preprocessed/embedding_input_patch_A_f32.hex \
  --output-dir build/model_package/v1
```

Một lần chạy thành công phải tạo:

```text
build/model_package/v1/
├── vit_model.bin
├── vit_model_table.bin
├── prepared_input.bin
├── vit_model_table.json
└── hash_manifest.json
```

Không chỉnh sửa thủ công file binary sau khi pack. Bất kỳ thay đổi byte nào
cũng làm sai CRC/SHA và phá contract với table.

### 12.1. Sinh cấu hình runtime cho AXI-Lite

Sau khi pack, tạo contract mà host/BFM dùng để ghi register:

```bash
python3 tools/generate_vit_runtime_config.py
```

Tool đọc trực tiếp `vit_model_table.bin` làm nguồn chuẩn, kiểm tra header,
CRC của header/entry, canonical order 200 tensor, alignment/range, rồi
cross-check CRC/SHA/kích thước của ba binary với `hash_manifest.json`. Nếu
`preprocessed/preprocess_manifest.json` tồn tại, tool còn kiểm tra SHA-256 và
số word của source HEX với đúng `prepared_input.bin`, sau đó đính kèm
provenance ảnh/processor vào output.

Kết quả `build/model_package/v1/vit_runtime_config.json` chứa:

- `MODEL_WORDS`, `INPUT_WORDS`, `SCRATCH_WORDS`;
- tám global model word offset theo đúng thứ tự register `0x080..0x09c`;
- 12 bảng layer, mỗi bảng 16 model word offset theo thứ tự `0x400..0x6fc`;
- E05 `JOB_CONFIG = 0x00001D85`, `PATCH_A_BASE = 0`, class Softmax và
  checkpoint được bật, do đó kỳ vọng 249 command/checkpoint;
- hash và provenance cần để host/BFM log đúng asset đã chạy.

File runtime **không chứa địa chỉ DDR vật lý**. A53/BFM vẫn phải allocate ba
vùng không overlap, ghi `MODEL_BASE`, `INPUT_BASE`, `SCRATCH_BASE`, copy payload
và xử lý cache coherency theo mục 11. Tool cũng từ chối mọi table offset/count
không vừa register word-address 32 bit hoặc có end-exclusive vượt không gian
logical 32 bit.

Chạy regression độc lập của contract:

```bash
scripts/checks/check_runtime_contract.sh
```

Regression kiểm tra package hiện tại, thứ tự `8 + 12×16` offset, encoding E05,
249 command, 101 command dùng parameter và các negative case u64→u32.

## 13. Các invariant để SW/HW dùng làm assertion

```text
TABLE_MAGIC            = "VITMTBL\0"
TABLE_VERSION          = 1.0
TABLE_HEADER_BYTES     = 128
TABLE_ENTRY_BYTES      = 64
TABLE_ENTRY_COUNT      = 200
TABLE_TOTAL_BYTES      = 12928
MODEL_ALIGNMENT_BYTES  = 64
MODEL_SOURCE_WORDS     = 86567656
MODEL_STORAGE_WORDS    = 86567664
MODEL_PADDING_WORDS    = 8
MODEL_TOTAL_BYTES      = 346270656
INPUT_WORDS            = 150528
INPUT_BYTES            = 602112
GLOBAL_ENTRY_COUNT     = 8
ENCODER_LAYER_COUNT    = 12
ENTRIES_PER_LAYER      = 16
```

Các assertion quan trọng:

```text
model_bytes == storage_words * 4
source_words + padding_words == storage_words
entries_offset + entry_count * entry_bytes == table_bytes
tensor_id == entry_index
word_offset % 16 == 0
word_offset + word_count <= storage_words
layer_tensor_id == 8 + layer * 16 + slot
physical_address == memory_space_base + (word_offset << 2)
```

Nếu cần thay tensor order, thêm dtype, đổi alignment, nhúng table vào model hay
thay ý nghĩa field, phải tạo phiên bản format mới. Không tái sử dụng
`version_major=1, version_minor=0` cho một ABI không tương thích.
