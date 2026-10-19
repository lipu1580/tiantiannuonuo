// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtb_sample_tick_gen.h for the primary calling header

#include "Vtb_sample_tick_gen__pch.h"

VlCoroutine Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__0(Vtb_sample_tick_gen___024root* vlSelf);
VlCoroutine Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__1(Vtb_sample_tick_gen___024root* vlSelf);

void Vtb_sample_tick_gen___024root___eval_initial(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_initial\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__0(vlSelf);
    Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__1(vlSelf);
}

void Vtb_sample_tick_gen___024root____VbeforeTrig_h72feffa9__0(Vtb_sample_tick_gen___024root* vlSelf, const char* __VeventDescription);
void Vtb_sample_tick_gen___024root____VbeforeTrig_h72ff0078__0(Vtb_sample_tick_gen___024root* vlSelf, const char* __VeventDescription);

VlCoroutine Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__0(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__0\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    IData/*31:0*/ tb_sample_tick_gen__DOT__unnamedblk1_1__DOT____Vrepeat0;
    tb_sample_tick_gen__DOT__unnamedblk1_1__DOT____Vrepeat0 = 0;
    // Body
    vlSelfRef.tb_sample_tick_gen__DOT__rst_n = 0U;
    co_await vlSelfRef.__VdlySched.delay(0x000000000000001eULL, 
                                         nullptr, "sim/tb_sample_tick_gen.sv", 
                                         65);
    co_await vlSelfRef.__VdlySched.delay(1ULL, nullptr, 
                                         "sim/tb_sample_tick_gen.sv", 
                                         66);
    vlSelfRef.tb_sample_tick_gen__DOT__rst_n = 1U;
    tb_sample_tick_gen__DOT__unnamedblk1_1__DOT____Vrepeat0 = 0x00000028U;
    while (VL_LTS_III(32, 0U, tb_sample_tick_gen__DOT__unnamedblk1_1__DOT____Vrepeat0)) {
        Vtb_sample_tick_gen___024root____VbeforeTrig_h72feffa9__0(vlSelf, 
                                                                  "@(posedge tb_sample_tick_gen.sys_clk)");
        co_await vlSelfRef.__VtrigSched_h72feffa9__0.trigger(0U, 
                                                             nullptr, 
                                                             "@(posedge tb_sample_tick_gen.sys_clk)", 
                                                             "sim/tb_sample_tick_gen.sv", 
                                                             69);
        tb_sample_tick_gen__DOT__unnamedblk1_1__DOT____Vrepeat0 
            = (tb_sample_tick_gen__DOT__unnamedblk1_1__DOT____Vrepeat0 
               - (IData)(1U));
    }
    Vtb_sample_tick_gen___024root____VbeforeTrig_h72ff0078__0(vlSelf, 
                                                              "@(negedge tb_sample_tick_gen.sys_clk)");
    co_await vlSelfRef.__VtrigSched_h72ff0078__0.trigger(0U, 
                                                         nullptr, 
                                                         "@(negedge tb_sample_tick_gen.sys_clk)", 
                                                         "sim/tb_sample_tick_gen.sv", 
                                                         70);
    co_await vlSelfRef.__VdlySched.delay(1ULL, nullptr, 
                                         "sim/tb_sample_tick_gen.sv", 
                                         71);
    if (VL_UNLIKELY(((VL_GTS_III(32, 0x0000000bU, vlSelfRef.tb_sample_tick_gen__DOT__pulse_count) 
                      | VL_LTS_III(32, 0x0000000dU, vlSelfRef.tb_sample_tick_gen__DOT__pulse_count))))) {
        VL_WRITEF_NX("[%0t] %%Error: tb_sample_tick_gen.sv:74: Assertion failed in %m: Expect:12, now: %0d \n",4, 'M',vlSymsp->name(),"tb_sample_tick_gen", 'T',-9
                     , '#',64,VL_TIME_UNITED_Q(1), '~',32,vlSelfRef.tb_sample_tick_gen__DOT__pulse_count);
        VL_STOP_MT("sim/tb_sample_tick_gen.sv", 74, "");
    }
    VL_WRITEF_NX("pusle_count = %0d cycle_count = %0d\n",2
                 , '~',32,vlSelfRef.tb_sample_tick_gen__DOT__pulse_count
                 , '~',32,vlSelfRef.tb_sample_tick_gen__DOT__cycle_count);
    VL_FINISH_MT("sim/tb_sample_tick_gen.sv", 78, "");
    co_return;
}

VlCoroutine Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__1(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_initial__TOP__Vtiming__1\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    while (VL_LIKELY(!vlSymsp->_vm_contextp__->gotFinish())) {
        vlSelfRef.tb_sample_tick_gen__DOT__sys_clk = 0U;
        co_await vlSelfRef.__VdlySched.delay(5ULL, 
                                             nullptr, 
                                             "sim/tb_sample_tick_gen.sv", 
                                             16);
        vlSelfRef.tb_sample_tick_gen__DOT__sys_clk = 1U;
        co_await vlSelfRef.__VdlySched.delay(5ULL, 
                                             nullptr, 
                                             "sim/tb_sample_tick_gen.sv", 
                                             17);
    }
    co_return;
}

bool Vtb_sample_tick_gen___024root___trigger_anySet__act(const VlUnpacked<QData/*63:0*/, 1> &in) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___trigger_anySet__act\n"); );
    // Locals
    IData/*31:0*/ n;
    // Body
    n = 0U;
    do {
        if (in[n]) {
            return (1U);
        }
        n = ((IData)(1U) + n);
    } while ((1U > n));
    return (0U);
}

void Vtb_sample_tick_gen___024root___timing_ready(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___timing_ready\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((2ULL & vlSelfRef.__VactTriggered[0U])) {
        vlSelfRef.__VtrigSched_h72feffa9__0.ready("@(posedge tb_sample_tick_gen.sys_clk)");
    }
    if ((1ULL & vlSelfRef.__VactTriggered[0U])) {
        vlSelfRef.__VtrigSched_h72ff0078__0.ready("@(negedge tb_sample_tick_gen.sys_clk)");
    }
}

void Vtb_sample_tick_gen___024root___timing_resume(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___timing_resume\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__VtrigSched_h72feffa9__0.moveToResumeQueue(
                                                          "@(posedge tb_sample_tick_gen.sys_clk)");
    vlSelfRef.__VtrigSched_h72ff0078__0.moveToResumeQueue(
                                                          "@(negedge tb_sample_tick_gen.sys_clk)");
    vlSelfRef.__VtrigSched_h72feffa9__0.resume("@(posedge tb_sample_tick_gen.sys_clk)");
    vlSelfRef.__VtrigSched_h72ff0078__0.resume("@(negedge tb_sample_tick_gen.sys_clk)");
    if ((4ULL & vlSelfRef.__VactTriggered[0U])) {
        vlSelfRef.__VdlySched.resume();
    }
}

void Vtb_sample_tick_gen___024root___trigger_orInto__act_vec_vec(VlUnpacked<QData/*63:0*/, 1> &out, const VlUnpacked<QData/*63:0*/, 1> &in) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___trigger_orInto__act_vec_vec\n"); );
    // Locals
    IData/*31:0*/ n;
    // Body
    n = 0U;
    do {
        out[n] = (out[n] | in[n]);
        n = ((IData)(1U) + n);
    } while ((0U >= n));
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_sample_tick_gen___024root___dump_triggers__act(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag);
#endif  // VL_DEBUG

bool Vtb_sample_tick_gen___024root___eval_phase__act(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_phase__act\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    CData/*0:0*/ __VactExecute;
    // Body
    {
        // Inlined CFunc: _eval_triggers_vec__act
        vlSelfRef.__VactTriggered[0U] = (QData)((IData)(
                                                        ((vlSelfRef.__VdlySched.awaitingCurrentTime() 
                                                          << 2U) 
                                                         | ((((IData)(vlSelfRef.tb_sample_tick_gen__DOT__sys_clk) 
                                                              & (~ (IData)(vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0))) 
                                                             << 1U) 
                                                            | ((~ (IData)(vlSelfRef.tb_sample_tick_gen__DOT__sys_clk)) 
                                                               & (IData)(vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0))))));
        vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0 
            = vlSelfRef.tb_sample_tick_gen__DOT__sys_clk;
    }
    Vtb_sample_tick_gen___024root___timing_ready(vlSelf);
    Vtb_sample_tick_gen___024root___trigger_orInto__act_vec_vec(vlSelfRef.__VactTriggered, vlSelfRef.__VactTriggeredAcc);
#ifdef VL_DEBUG
    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->debug())) {
        Vtb_sample_tick_gen___024root___dump_triggers__act(vlSelfRef.__VactTriggered, "act"s);
    }
#endif
    Vtb_sample_tick_gen___024root___trigger_orInto__act_vec_vec(vlSelfRef.__VnbaTriggered, vlSelfRef.__VactTriggered);
    __VactExecute = Vtb_sample_tick_gen___024root___trigger_anySet__act(vlSelfRef.__VactTriggered);
    if (__VactExecute) {
        vlSelfRef.__VactTriggeredAcc.fill(0ULL);
        Vtb_sample_tick_gen___024root___timing_resume(vlSelf);
    }
    return (__VactExecute);
}

bool Vtb_sample_tick_gen___024root___eval_phase__inact(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_phase__inact\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    CData/*0:0*/ __VinactExecute;
    // Body
    __VinactExecute = vlSelfRef.__VdlySched.awaitingZeroDelay();
    if (__VinactExecute) {
        VL_FATAL_MT("sim/tb_sample_tick_gen.sv", 3, "", "ZERODLY: Design Verilated with '--no-sched-zero-delay', but #0 delay executed at runtime");
    }
    return (__VinactExecute);
}

void Vtb_sample_tick_gen___024root___trigger_clear__act(VlUnpacked<QData/*63:0*/, 1> &out) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___trigger_clear__act\n"); );
    // Locals
    IData/*31:0*/ n;
    // Body
    n = 0U;
    do {
        out[n] = 0ULL;
        n = ((IData)(1U) + n);
    } while ((1U > n));
}

bool Vtb_sample_tick_gen___024root___eval_phase__nba(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_phase__nba\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    CData/*0:0*/ __VnbaExecute;
    // Body
    __VnbaExecute = Vtb_sample_tick_gen___024root___trigger_anySet__act(vlSelfRef.__VnbaTriggered);
    if (__VnbaExecute) {
        {
            // Inlined CFunc: _eval_nba
            if ((2ULL & vlSelfRef.__VnbaTriggered[0U])) {
                {
                    // Inlined CFunc: _nba_sequent__TOP__0
                    IData/*31:0*/ __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator;
                    __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator = 0;
                    __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator 
                        = vlSelfRef.tb_sample_tick_gen__DOT__DUT__DOT__accumulator;
                    if (vlSelfRef.tb_sample_tick_gen__DOT__rst_n) {
                        if ((0x0000000aU <= ((IData)(3U) 
                                             + vlSelfRef.tb_sample_tick_gen__DOT__DUT__DOT__accumulator))) {
                            __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator 
                                = ((IData)(0xfffffff9U) 
                                   + vlSelfRef.tb_sample_tick_gen__DOT__DUT__DOT__accumulator);
                            vlSelfRef.tb_sample_tick_gen__DOT__audio_ce = 1U;
                        } else {
                            __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator 
                                = ((IData)(3U) + vlSelfRef.tb_sample_tick_gen__DOT__DUT__DOT__accumulator);
                            vlSelfRef.tb_sample_tick_gen__DOT__audio_ce = 0U;
                        }
                    } else {
                        __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator = 0U;
                        vlSelfRef.tb_sample_tick_gen__DOT__audio_ce = 0U;
                    }
                    vlSelfRef.tb_sample_tick_gen__DOT__DUT__DOT__accumulator 
                        = __Vinline_0__eval_nba___Vinline_0__nba_sequent__TOP__0___Vdly__tb_sample_tick_gen__DOT__DUT__DOT__accumulator;
                }
            }
            if ((1ULL & vlSelfRef.__VnbaTriggered[0U])) {
                {
                    // Inlined CFunc: _nba_sequent__TOP__1
                    if (vlSelfRef.tb_sample_tick_gen__DOT__rst_n) {
                        vlSelfRef.tb_sample_tick_gen__DOT__cycle_count 
                            = ((IData)(1U) + vlSelfRef.tb_sample_tick_gen__DOT__cycle_count);
                        if (VL_UNLIKELY((((IData)(vlSelfRef.tb_sample_tick_gen__DOT__prev_audio_ce) 
                                          & (IData)(vlSelfRef.tb_sample_tick_gen__DOT__audio_ce))))) {
                            VL_WRITEF_NX("[%0t] %%Error: tb_sample_tick_gen.sv:45: Assertion failed in %m: Audio_ce can't stable for multipy period\n\n",3, 'M',vlSymsp->name(),"tb_sample_tick_gen", 'T',-9
                                         , '#',64,VL_TIME_UNITED_Q(1));
                            VL_STOP_MT("sim/tb_sample_tick_gen.sv", 45, "");
                        }
                        if (vlSelfRef.tb_sample_tick_gen__DOT__audio_ce) {
                            vlSelfRef.tb_sample_tick_gen__DOT__pulse_count 
                                = ((IData)(1U) + vlSelfRef.tb_sample_tick_gen__DOT__pulse_count);
                            if (VL_LTES_III(32, 0U, vlSelfRef.tb_sample_tick_gen__DOT__last_pulse_cycle)) {
                                vlSelfRef.tb_sample_tick_gen__DOT__unnamedblk1__DOT__interval 
                                    = (vlSelfRef.tb_sample_tick_gen__DOT__cycle_count 
                                       - vlSelfRef.tb_sample_tick_gen__DOT__last_pulse_cycle);
                                if (VL_UNLIKELY(((VL_GTS_III(32, 3U, vlSelfRef.tb_sample_tick_gen__DOT__unnamedblk1__DOT__interval) 
                                                  | VL_LTS_III(32, 4U, vlSelfRef.tb_sample_tick_gen__DOT__unnamedblk1__DOT__interval))))) {
                                    VL_WRITEF_NX("[%0t] %%Error: tb_sample_tick_gen.sv:53: Assertion failed in %m: interval=%0d ERROR @cycle %0d\n",5, 'M',vlSymsp->name(),"tb_sample_tick_gen.unnamedblk1", 'T',-9
                                                 , '#',64,VL_TIME_UNITED_Q(1)
                                                 , '~',32,vlSelfRef.tb_sample_tick_gen__DOT__unnamedblk1__DOT__interval
                                                 , '~',32,vlSelfRef.tb_sample_tick_gen__DOT__cycle_count);
                                    VL_STOP_MT("sim/tb_sample_tick_gen.sv", 53, "");
                                }
                            }
                            vlSelfRef.tb_sample_tick_gen__DOT__last_pulse_cycle 
                                = vlSelfRef.tb_sample_tick_gen__DOT__cycle_count;
                            vlSelfRef.tb_sample_tick_gen__DOT__prev_audio_ce = 1U;
                        } else {
                            vlSelfRef.tb_sample_tick_gen__DOT__prev_audio_ce = 0U;
                        }
                    } else {
                        vlSelfRef.tb_sample_tick_gen__DOT__pulse_count = 0U;
                        vlSelfRef.tb_sample_tick_gen__DOT__cycle_count = 0U;
                        vlSelfRef.tb_sample_tick_gen__DOT__last_pulse_cycle = 0xffffffffU;
                        vlSelfRef.tb_sample_tick_gen__DOT__prev_audio_ce = 0U;
                    }
                }
            }
        }
        Vtb_sample_tick_gen___024root___trigger_clear__act(vlSelfRef.__VnbaTriggered);
    }
    return (__VnbaExecute);
}

void Vtb_sample_tick_gen___024root___eval(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    IData/*31:0*/ __VnbaIterCount;
    // Body
    __VnbaIterCount = 0U;
    do {
        if (VL_UNLIKELY(((0x00002710U < __VnbaIterCount)))) {
#ifdef VL_DEBUG
            Vtb_sample_tick_gen___024root___dump_triggers__act(vlSelfRef.__VnbaTriggered, "nba"s);
#endif
            VL_FATAL_MT("sim/tb_sample_tick_gen.sv", 3, "", "DIDNOTCONVERGE: NBA region did not converge after '--converge-limit' of 10000 tries");
        }
        __VnbaIterCount = ((IData)(1U) + __VnbaIterCount);
        vlSelfRef.__VinactIterCount = 0U;
        do {
            if (VL_UNLIKELY(((0x00002710U < vlSelfRef.__VinactIterCount)))) {
                VL_FATAL_MT("sim/tb_sample_tick_gen.sv", 3, "", "DIDNOTCONVERGE: Inactive region did not converge after '--converge-limit' of 10000 tries");
            }
            vlSelfRef.__VinactIterCount = ((IData)(1U) 
                                           + vlSelfRef.__VinactIterCount);
            vlSelfRef.__VactIterCount = 0U;
            do {
                if (VL_UNLIKELY(((0x00002710U < vlSelfRef.__VactIterCount)))) {
#ifdef VL_DEBUG
                    Vtb_sample_tick_gen___024root___dump_triggers__act(vlSelfRef.__VactTriggered, "act"s);
#endif
                    VL_FATAL_MT("sim/tb_sample_tick_gen.sv", 3, "", "DIDNOTCONVERGE: Active region did not converge after '--converge-limit' of 10000 tries");
                }
                vlSelfRef.__VactIterCount = ((IData)(1U) 
                                             + vlSelfRef.__VactIterCount);
                vlSelfRef.__VactPhaseResult = Vtb_sample_tick_gen___024root___eval_phase__act(vlSelf);
            } while (vlSelfRef.__VactPhaseResult);
            vlSelfRef.__VinactPhaseResult = Vtb_sample_tick_gen___024root___eval_phase__inact(vlSelf);
        } while (vlSelfRef.__VinactPhaseResult);
        vlSelfRef.__VnbaPhaseResult = Vtb_sample_tick_gen___024root___eval_phase__nba(vlSelf);
    } while (vlSelfRef.__VnbaPhaseResult);
}

void Vtb_sample_tick_gen___024root____VbeforeTrig_h72feffa9__0(Vtb_sample_tick_gen___024root* vlSelf, const char* __VeventDescription) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root____VbeforeTrig_h72feffa9__0\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    VlUnpacked<QData/*63:0*/, 1> __VTmp;
    // Body
    __VTmp[0U] = (QData)((IData)(((((IData)(vlSelfRef.tb_sample_tick_gen__DOT__sys_clk) 
                                    & (~ (IData)(vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0))) 
                                   << 1U) | ((~ (IData)(vlSelfRef.tb_sample_tick_gen__DOT__sys_clk)) 
                                             & (IData)(vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0)))));
    vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0 
        = vlSelfRef.tb_sample_tick_gen__DOT__sys_clk;
    if ((1ULL & __VTmp[0U])) {
        vlSelfRef.__VtrigSched_h72ff0078__0.ready(__VeventDescription);
    }
    if ((2ULL & __VTmp[0U])) {
        vlSelfRef.__VtrigSched_h72feffa9__0.ready(__VeventDescription);
    }
    vlSelfRef.__VactTriggeredAcc[0U] = (vlSelfRef.__VactTriggeredAcc[0U] 
                                        | __VTmp[0U]);
}

void Vtb_sample_tick_gen___024root____VbeforeTrig_h72ff0078__0(Vtb_sample_tick_gen___024root* vlSelf, const char* __VeventDescription) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root____VbeforeTrig_h72ff0078__0\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    VlUnpacked<QData/*63:0*/, 1> __VTmp;
    // Body
    __VTmp[0U] = (QData)((IData)(((((IData)(vlSelfRef.tb_sample_tick_gen__DOT__sys_clk) 
                                    & (~ (IData)(vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0))) 
                                   << 1U) | ((~ (IData)(vlSelfRef.tb_sample_tick_gen__DOT__sys_clk)) 
                                             & (IData)(vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0)))));
    vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0 
        = vlSelfRef.tb_sample_tick_gen__DOT__sys_clk;
    if ((1ULL & __VTmp[0U])) {
        vlSelfRef.__VtrigSched_h72ff0078__0.ready(__VeventDescription);
    }
    if ((2ULL & __VTmp[0U])) {
        vlSelfRef.__VtrigSched_h72feffa9__0.ready(__VeventDescription);
    }
    vlSelfRef.__VactTriggeredAcc[0U] = (vlSelfRef.__VactTriggeredAcc[0U] 
                                        | __VTmp[0U]);
}

#ifdef VL_DEBUG
void Vtb_sample_tick_gen___024root___eval_debug_assertions(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_debug_assertions\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
}
#endif  // VL_DEBUG
