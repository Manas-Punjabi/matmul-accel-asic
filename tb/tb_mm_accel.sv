`timescale 1ns/1ps
// tb_mm_accel.sv — self-checking testbench
//
//  ID   Test                 Checks
//  T1   identity             I x B == B
//  T2   overflow             all-ones operands; modulo-2^DW wraparound
//  T3   zeros                0 x B == 0 (clears previous result)
//  T4   random x20           golden model, back-to-back runs, no reset between
//  T5   latency              done arrives exactly N+4+SPLIT_MUL cycles after start
//  T6   done_pulse           done is high for exactly one cycle
//  T7   load_while_busy      we_a/we_b ignored while busy; A/B/C unaffected
//       (T7 re-runs without reloading, so any A/B corruption is exposed)
//  T8   start_while_busy     extra start ignored; exactly one done
//  T9   reset_mid_run        rst_n during busy -> idle, no done; next run is correct
//  T10  busy_flag            busy high throughout RUN, low when idle
//  T0   reset_state          busy/done low and PE valids known-0 after reset
//                            (whitebox part skipped with +define+GLS)
//
// T5, T6 and T10 are assertions inside run_case, so they apply to all 27 runs
// per configuration. T9 is reset_mid_run. The rest are called from the main block.
//
// Build modes: plain RTL; +define+GLS for a gate-level netlist (parameters baked in);
// +define+SDF with +sdf=<file> to back-annotate delays (see docs/verification.md).
module tb_mm_accel;
  parameter int N  = 4;
  parameter int DW = 32;
  parameter int SPLIT_MUL = 0;
  parameter int HALF_PERIOD = 5;         // ns; raise for SDF-annotated runs at longer periods
  parameter int RD_SETTLE = 1;           // ns between driving raddr and sampling rdata
  localparam int AW = $clog2(N*N);
  localparam int EXP_LAT = N + 4 + SPLIT_MUL;

  logic clk = 0, rst_n = 0;
  always #(HALF_PERIOD) clk = ~clk;

  logic          we_a = 0, we_b = 0, start = 0, busy, done;
  logic [AW-1:0] waddr = '0, raddr = '0;
  logic [DW-1:0] wdata = '0, rdata;

`ifdef GLS
  mm_accel dut (                         // synthesized netlist: parameters are baked in
`else
  mm_accel #(.N(N), .DW(DW), .SPLIT_MUL(SPLIT_MUL)) dut (
`endif
    .clk(clk), .rst_n(rst_n), .we_a(we_a), .we_b(we_b), .waddr(waddr),
    .wdata(wdata), .start(start), .busy(busy), .done(done),
    .raddr(raddr), .rdata(rdata)
  );

`ifdef SDF
  // post-layout timing simulation: vvp ... +sdf=<file>
  string sdf_file;
  initial if ($value$plusargs("sdf=%s", sdf_file)) $sdf_annotate(sdf_file, dut);
`endif

  logic [DW-1:0] A [0:N*N-1];
  logic [DW-1:0] B [0:N*N-1];
  logic [DW-1:0] C [0:N*N-1];
  int errors = 0, checks = 0;

  // hook selection for directed tests
  typedef enum {H_NONE, H_LOAD_BUSY, H_START_BUSY} hook_t;

  task automatic fail(input string msg);
    errors++;
    $display("  FAIL: %s", msg);
  endtask

  task automatic golden();
    logic [DW-1:0] acc;
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        acc = '0;
        for (int k = 0; k < N; k++) acc = acc + A[i*N+k] * B[k*N+j];
        C[i*N+j] = acc;
      end
  endtask

  task automatic load();
    for (int x = 0; x < N*N; x++) begin
      @(negedge clk); waddr = x[AW-1:0]; we_a = 1; we_b = 0; wdata = A[x];
      @(negedge clk);                    we_a = 0; we_b = 1; wdata = B[x];
    end
    @(negedge clk); we_b = 0;
  endtask

  task automatic readback(input string name);
    for (int x = 0; x < N*N; x++) begin
      raddr = x[AW-1:0]; #(RD_SETTLE);
      checks++;
      if (rdata !== C[x])
        fail($sformatf("%s C[%0d]: got %h exp %h", name, x, rdata, C[x]));
    end
  endtask

  task automatic run_case(input string name, input hook_t hook = H_NONE,
                          input bit reload = 1'b1);
    int cyc, done_cnt;
    golden();
    if (reload) load();
    @(negedge clk);                      // re-align after readback drift
    start = 1; @(negedge clk); start = 0;
    cyc = 1; done_cnt = 0;
    while (!done) begin
      if (!busy) fail($sformatf("%s: busy low before done (cycle %0d)", name, cyc));
      if (hook == H_LOAD_BUSY) begin        // try to corrupt A and B mid-run
        we_a = 1; we_b = 1; waddr = (N*N - 1) - (cyc % (N*N)); wdata = ~A[waddr];
      end
      if (hook == H_START_BUSY && cyc == 2) start = 1;
      @(negedge clk);
      we_a = 0; we_b = 0; start = 0;
      cyc++;
      if (cyc > 10*EXP_LAT) begin
        $display("  FAIL: %s: no done", name); $display("FAIL: hang"); $finish;
      end
    end
    checks++;
    if (cyc != EXP_LAT)
      fail($sformatf("%s: latency %0d, expected %0d", name, cyc, EXP_LAT));
    // done must be a single-cycle pulse, and no second done may follow
    for (int t = 0; t < 2*EXP_LAT; t++) begin
      if (done) done_cnt++;
      if (t > 0 && busy) fail($sformatf("%s: busy high after done", name));
      @(negedge clk);
    end
    checks++;
    if (done_cnt != 1) fail($sformatf("%s: done seen %0d cycles, expected 1", name, done_cnt));
    readback(name);
    $display("[%s] ok (latency %0d)", name, cyc);
  endtask

  task automatic reset_mid_run();
    int saw_activity = 0;
    for (int x = 0; x < N*N; x++) begin A[x] = $urandom; B[x] = $urandom; end
    load();
    start = 1; @(negedge clk); start = 0;
    @(negedge clk);
    rst_n = 0; @(negedge clk);
    checks++;
    if (busy || done) fail("reset_mid_run: busy/done not cleared by reset");
    rst_n = 1;
    for (int t = 0; t < 2*EXP_LAT; t++) begin
      if (done || busy) saw_activity++;
      @(negedge clk);
    end
    checks++;
    if (saw_activity) fail("reset_mid_run: activity after reset without start");
    $display("[reset_mid_run] aborted cleanly");
    run_case("reset_mid_run.rerun");   // storage is reset-free: rerun reloads
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_mm_accel.vcd");
      $dumpvars(0, tb_mm_accel);
    end
    repeat (3) @(negedge clk); rst_n = 1;
    @(negedge clk);
    checks++;
    if (busy || done) fail("T0.reset_state: busy/done not low");
`ifndef GLS
    checks++;
    if ($isunknown(dut.pe_v) || dut.pe_v != '0)
      fail($sformatf("T0.reset_state: PE valid = %b after reset", dut.pe_v));
`endif

    for (int x = 0; x < N*N; x++) begin
      A[x] = (x / N == x % N) ? 1 : 0;
      B[x] = $urandom;
    end
    run_case("T1.identity");

    for (int x = 0; x < N*N; x++) begin A[x] = '1; B[x] = '1; end
    run_case("T2.overflow");

    for (int x = 0; x < N*N; x++) begin A[x] = '0; B[x] = $urandom; end
    run_case("T3.zeros");

    for (int r = 0; r < 20; r++) begin
      for (int x = 0; x < N*N; x++) begin A[x] = $urandom; B[x] = $urandom; end
      run_case($sformatf("T4.random%0d", r));
    end

    for (int x = 0; x < N*N; x++) begin A[x] = $urandom; B[x] = $urandom; end
    run_case("T7.load_while_busy", H_LOAD_BUSY);
    run_case("T7.rerun_no_reload", H_NONE, 1'b0);

    for (int x = 0; x < N*N; x++) begin A[x] = $urandom; B[x] = $urandom; end
    run_case("T8.start_while_busy", H_START_BUSY);

    reset_mid_run();

    if (errors == 0)
      $display("PASS: %0d checks, N=%0d DW=%0d SPLIT_MUL=%0d", checks, N, DW, SPLIT_MUL);
    else
      $display("FAIL: %0d errors / %0d checks", errors, checks);
    $finish;
  end

  initial begin #10_000_000; $display("FAIL: timeout"); $finish; end
endmodule
