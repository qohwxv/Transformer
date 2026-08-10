`timescale 1ns/1ps

module tb_vit_layer_param_table_loader;

    import vit_phase_e_pkg::*;

    logic clk = 1'b0;
    logic table_rst = 1'b1;
    logic loader_rst = 1'b1;

    logic a_en = 1'b0;
    logic [7:0] a_addr = 8'd0;
    logic [3:0] a_we = 4'd0;
    logic [31:0] a_wdata = 32'd0;
    logic a_rvalid;
    logic [31:0] a_rdata;

    logic b_en;
    logic [7:0] b_addr;
    logic b_rvalid;
    logic [31:0] b_rdata;
    logic manual_b_mode = 1'b0;
    logic manual_b_en = 1'b0;
    logic [7:0] manual_b_addr = 8'd0;

    logic loader_request = 1'b0;
    logic [3:0] loader_index = 4'd0;
    logic loader_response_valid;
    phase_e_layer_params_t loader_response_data;
    logic [16*32-1:0] loader_response_packed;
    logic loader_ram_valid;
    logic loader_ram_ready = 1'b1;
    logic [7:0] loader_ram_addr;

    integer checks = 0;
    integer failures = 0;
    integer loader_responses = 0;
    integer loader_requests = 0;
    integer expected_loader_address = 0;

    always #5 clk = ~clk;

    assign b_en = manual_b_mode ?
        manual_b_en : (loader_ram_valid && loader_ram_ready);
    assign b_addr = manual_b_mode ? manual_b_addr : loader_ram_addr;
    assign loader_response_data =
        phase_e_layer_params_t'(loader_response_packed);

    vit_layer_param_table table_i (
        .clk(clk),
        .rst(table_rst),
        .a_en_i(a_en),
        .a_addr_i(a_addr),
        .a_we_i(a_we),
        .a_wdata_i(a_wdata),
        .a_rvalid_o(a_rvalid),
        .a_rdata_o(a_rdata),
        .b_en_i(b_en),
        .b_addr_i(b_addr),
        .b_rvalid_o(b_rvalid),
        .b_rdata_o(b_rdata)
    );

    vit_layer_param_loader loader_i (
        .clk(clk),
        .rst(loader_rst),
        .request_i(loader_request),
        .index_i(loader_index),
        .response_valid_o(loader_response_valid),
        .response_data_o(loader_response_packed),
        .ram_req_valid_o(loader_ram_valid),
        .ram_req_ready_i(loader_ram_ready),
        .ram_req_addr_o(loader_ram_addr),
        .ram_rsp_valid_i(b_rvalid),
        .ram_rsp_data_i(b_rdata)
    );

    always @(posedge clk) begin
        if (loader_rst) begin
            loader_responses <= 0;
        end else if (loader_response_valid) begin
            loader_responses <= loader_responses + 1;
        end

        if (!loader_rst && loader_ram_valid && loader_ram_ready) begin
            loader_requests <= loader_requests + 1;
            check(
                loader_ram_addr == expected_loader_address[7:0],
                "loader issued ordered RAM address"
            );
            expected_loader_address <= expected_loader_address + 1;
        end
    end

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic port_a_access(
        input logic [7:0] address,
        input logic [3:0] write_enable,
        input logic [31:0] write_data,
        output logic [31:0] read_data
    );
        begin
            @(negedge clk);
            a_en = 1'b1;
            a_addr = address;
            a_we = write_enable;
            a_wdata = write_data;
            @(posedge clk);
            @(negedge clk);
            a_en = 1'b0;
            a_we = 4'd0;
            while (!a_rvalid)
                @(posedge clk);
            #1;
            read_data = a_rdata;
        end
    endtask

    task automatic port_a_write(
        input logic [7:0] address,
        input logic [3:0] write_enable,
        input logic [31:0] write_data
    );
        logic [31:0] ignored;
        begin
            port_a_access(address, write_enable, write_data, ignored);
        end
    endtask

    task automatic port_a_read(
        input logic [7:0] address,
        output logic [31:0] read_data
    );
        begin
            port_a_access(address, 4'd0, 32'd0, read_data);
        end
    endtask

    task automatic wait_loader_response(input integer timeout_cycles);
        integer waited;
        begin
            waited = 0;
            while (!loader_response_valid && waited < timeout_cycles) begin
                @(posedge clk);
                #1;
                waited = waited + 1;
            end
            check(loader_response_valid, "loader response arrived before timeout");
        end
    endtask

    task automatic check_loaded_layer(input logic [31:0] base);
        begin
            check(
                loader_response_data.ln1_gamma_base == base + 0,
                "loader word 0 mapping"
            );
            check(
                loader_response_data.ln1_beta_base == base + 1,
                "loader word 1 mapping"
            );
            check(
                loader_response_data.q_weight_base == base + 2,
                "loader word 2 mapping"
            );
            check(
                loader_response_data.q_bias_base == base + 3,
                "loader word 3 mapping"
            );
            check(
                loader_response_data.k_weight_base == base + 4,
                "loader word 4 mapping"
            );
            check(
                loader_response_data.k_bias_base == base + 5,
                "loader word 5 mapping"
            );
            check(
                loader_response_data.v_weight_base == base + 6,
                "loader word 6 mapping"
            );
            check(
                loader_response_data.v_bias_base == base + 7,
                "loader word 7 mapping"
            );
            check(
                loader_response_data.o_weight_base == base + 8,
                "loader word 8 mapping"
            );
            check(
                loader_response_data.o_bias_base == base + 9,
                "loader word 9 mapping"
            );
            check(
                loader_response_data.ln2_gamma_base == base + 10,
                "loader word 10 mapping"
            );
            check(
                loader_response_data.ln2_beta_base == base + 11,
                "loader word 11 mapping"
            );
            check(
                loader_response_data.fc1_weight_base == base + 12,
                "loader word 12 mapping"
            );
            check(
                loader_response_data.fc1_bias_base == base + 13,
                "loader word 13 mapping"
            );
            check(
                loader_response_data.fc2_weight_base == base + 14,
                "loader word 14 mapping"
            );
            check(
                loader_response_data.fc2_bias_base == base + 15,
                "loader word 15 mapping"
            );
        end
    endtask

    logic [31:0] read_data;
    integer word_index;
    integer response_count_before_hold;

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        table_rst = 1'b0;
        loader_rst = 1'b0;

        // Reset clears only validity; every never-written word reads zero.
        port_a_read(8'd0, read_data);
        check(read_data == 32'd0, "reset word reads zero on port A");

        // Byte strobes accumulate without exposing stale invalid bytes.
        port_a_write(8'd0, 4'b0101, 32'ha1b2_c3d4);
        port_a_read(8'd0, read_data);
        check(read_data == 32'h00b2_00d4, "partial first write masks bytes");
        port_a_write(8'd0, 4'b1010, 32'h1122_3344);
        port_a_read(8'd0, read_data);
        check(read_data == 32'h11b2_33d4, "complementary byte write merges");

        // Exercise simultaneous independent ports at different addresses.
        @(negedge clk);
        a_en = 1'b1;
        a_addr = 8'd7;
        a_we = 4'hf;
        a_wdata = 32'h7654_3210;
        manual_b_mode = 1'b1;
        manual_b_en = 1'b1;
        manual_b_addr = 8'd0;
        @(posedge clk);
        @(negedge clk);
        #1;
        check(a_rvalid && b_rvalid, "both synchronous ports responded");
        check(b_rdata == 32'h11b2_33d4, "port B independent read data");
        a_en = 1'b0;
        a_we = 4'd0;
        manual_b_en = 1'b0;
        manual_b_mode = 1'b0;
        port_a_read(8'd7, read_data);
        check(read_data == 32'h7654_3210, "port A simultaneous write stored");

        // Populate layer 3 (word addresses 48..63).
        for (word_index = 0; word_index < 16; word_index = word_index + 1)
            port_a_write(
                8'd48 + word_index[7:0],
                4'hf,
                32'h3000_0000 + word_index
            );

        // Hold request throughout the transaction and periodically stall the
        // RAM request channel.  Address/data must remain ordered.
        loader_requests = 0;
        expected_loader_address = 48;
        @(negedge clk);
        loader_index = 4'd3;
        loader_request = 1'b1;
        fork
            begin : ready_stalls
                repeat (40) begin
                    @(negedge clk);
                    loader_ram_ready =
                        ((loader_requests % 5) != 2)
                        && ((loader_requests % 7) != 4);
                end
                loader_ram_ready = 1'b1;
            end
            begin : wait_first_load
                wait_loader_response(100);
            end
        join
        check(loader_requests == 16, "loader accepted exactly 16 RAM reads");
        check_loaded_layer(32'h3000_0000);

        @(posedge clk);
        #1;
        response_count_before_hold = loader_responses;
        repeat (5) @(posedge clk);
        #1;
        check(
            loader_responses == response_count_before_hold,
            "held request produced exactly one response"
        );
        @(negedge clk);
        loader_request = 1'b0;
        repeat (2) @(posedge clk);

        // Reset only the loader part-way through a second request.  The table
        // remains intact; after request release the retry must load all words.
        loader_requests = 0;
        expected_loader_address = 48;
        @(negedge clk);
        loader_request = 1'b1;
        wait (loader_requests >= 5);
        @(negedge clk);
        loader_rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        loader_request = 1'b0;
        loader_rst = 1'b0;
        repeat (2) @(posedge clk);
        check(!loader_response_valid, "loader reset cancelled partial response");

        loader_requests = 0;
        expected_loader_address = 48;
        @(negedge clk);
        loader_request = 1'b1;
        wait_loader_response(80);
        check_loaded_layer(32'h3000_0000);
        @(negedge clk);
        loader_request = 1'b0;
        repeat (2) @(posedge clk);

        // Invalid indices complete once with a deterministic zero descriptor.
        @(negedge clk);
        loader_index = 4'd12;
        loader_request = 1'b1;
        wait_loader_response(10);
        check(loader_response_data == '0, "invalid layer response is zero");
        @(posedge clk);
        #1;
        response_count_before_hold = loader_responses;
        repeat (3) @(posedge clk);
        #1;
        check(
            loader_responses == response_count_before_hold,
            "invalid held request responded once"
        );
        @(negedge clk);
        loader_request = 1'b0;
        repeat (2) @(posedge clk);

        // Reset validity without resetting the underlying data array.  A new
        // partial write must not reveal stale bytes from the old full word.
        @(negedge clk);
        table_rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        table_rst = 1'b0;
        port_a_read(8'd7, read_data);
        check(read_data == 32'd0, "table reset masks prior RAM contents");
        port_a_write(8'd7, 4'b0001, 32'hffff_ff5a);
        port_a_read(8'd7, read_data);
        check(
            read_data == 32'h0000_005a,
            "post-reset partial write keeps stale bytes hidden"
        );

        if (failures == 0)
            $display(
                "VIT_LAYER_PARAM_TABLE_LOADER_TEST_PASS checks=%0d",
                checks
            );
        else
            $fatal(
                1,
                "layer table/loader failures=%0d checks=%0d",
                failures,
                checks
            );
        $finish;
    end

endmodule
