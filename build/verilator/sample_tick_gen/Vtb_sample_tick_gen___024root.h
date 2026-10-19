// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vtb_sample_tick_gen.h for the primary calling header

#ifndef VERILATED_VTB_SAMPLE_TICK_GEN___024ROOT_H_
#define VERILATED_VTB_SAMPLE_TICK_GEN___024ROOT_H_  // guard

#include "verilated.h"
#include "verilated_timing.h"


class Vtb_sample_tick_gen__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vtb_sample_tick_gen___024root final {
  public:

    // DESIGN SPECIFIC STATE
    CData/*0:0*/ tb_sample_tick_gen__DOT__sys_clk;
    CData/*0:0*/ tb_sample_tick_gen__DOT__rst_n;
    CData/*0:0*/ tb_sample_tick_gen__DOT__audio_ce;
    CData/*0:0*/ tb_sample_tick_gen__DOT__prev_audio_ce;
    CData/*0:0*/ __Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0;
    CData/*0:0*/ __VactPhaseResult;
    CData/*0:0*/ __VinactPhaseResult;
    CData/*0:0*/ __VnbaPhaseResult;
    IData/*31:0*/ tb_sample_tick_gen__DOT__pulse_count;
    IData/*31:0*/ tb_sample_tick_gen__DOT__cycle_count;
    IData/*31:0*/ tb_sample_tick_gen__DOT__last_pulse_cycle;
    IData/*31:0*/ tb_sample_tick_gen__DOT__unnamedblk1__DOT__interval;
    IData/*31:0*/ tb_sample_tick_gen__DOT__DUT__DOT__accumulator;
    IData/*31:0*/ __VactIterCount;
    IData/*31:0*/ __VinactIterCount;
    IData/*31:0*/ __Vi;
    VlUnpacked<QData/*63:0*/, 1> __VactTriggered;
    VlUnpacked<QData/*63:0*/, 1> __VactTriggeredAcc;
    VlUnpacked<QData/*63:0*/, 1> __VnbaTriggered;
    VlDelayScheduler __VdlySched;
    VlTriggerScheduler __VtrigSched_h72feffa9__0;
    VlTriggerScheduler __VtrigSched_h72ff0078__0;

    // INTERNAL VARIABLES
    Vtb_sample_tick_gen__Syms* vlSymsp;
    const char* vlNamep;

    // CONSTRUCTORS
    Vtb_sample_tick_gen___024root(Vtb_sample_tick_gen__Syms* symsp, const char* namep);
    ~Vtb_sample_tick_gen___024root();
    VL_UNCOPYABLE(Vtb_sample_tick_gen___024root);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard
