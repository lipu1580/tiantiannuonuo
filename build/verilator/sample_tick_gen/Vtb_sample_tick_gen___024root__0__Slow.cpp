// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtb_sample_tick_gen.h for the primary calling header

#include "Vtb_sample_tick_gen__pch.h"

void Vtb_sample_tick_gen___024root___timing_ready(Vtb_sample_tick_gen___024root* vlSelf);

VL_ATTR_COLD void Vtb_sample_tick_gen___024root___eval_static(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_static\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    {
        // Inlined CFunc: _eval_static__TOP
        vlSelfRef.tb_sample_tick_gen__DOT__last_pulse_cycle = 0xffffffffU;
        vlSelfRef.tb_sample_tick_gen__DOT__unnamedblk1__DOT__interval = 0U;
    }
    vlSelfRef.__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0 
        = vlSelfRef.tb_sample_tick_gen__DOT__sys_clk;
    Vtb_sample_tick_gen___024root___timing_ready(vlSelf);
    do {
        vlSelfRef.__VactTriggeredAcc[vlSelfRef.__Vi] 
            = vlSelfRef.__VactTriggered[vlSelfRef.__Vi];
        vlSelfRef.__Vi = ((IData)(1U) + vlSelfRef.__Vi);
    } while ((0U >= vlSelfRef.__Vi));
}

VL_ATTR_COLD void Vtb_sample_tick_gen___024root___eval_final(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_final\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
}

VL_ATTR_COLD void Vtb_sample_tick_gen___024root___eval_settle(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___eval_settle\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
}

bool Vtb_sample_tick_gen___024root___trigger_anySet__act(const VlUnpacked<QData/*63:0*/, 1> &in);

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtb_sample_tick_gen___024root___dump_triggers__act(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___dump_triggers__act\n"); );
    // Body
    if ((1U & (~ (IData)(Vtb_sample_tick_gen___024root___trigger_anySet__act(triggers))))) {
        VL_DBG_MSGS("         No '" + tag + "' region triggers active\n");
    }
    if ((1U & (IData)(triggers[0U]))) {
        VL_DBG_MSGS("         '" + tag + "' region trigger index 0 is active: @(negedge tb_sample_tick_gen.sys_clk)\n");
    }
    if ((1U & (IData)((triggers[0U] >> 1U)))) {
        VL_DBG_MSGS("         '" + tag + "' region trigger index 1 is active: @(posedge tb_sample_tick_gen.sys_clk)\n");
    }
    if ((1U & (IData)((triggers[0U] >> 2U)))) {
        VL_DBG_MSGS("         '" + tag + "' region trigger index 2 is active: @([true] __VdlySched.awaitingCurrentTime())\n");
    }
}
#endif  // VL_DEBUG

VL_ATTR_COLD void Vtb_sample_tick_gen___024root___ctor_var_reset(Vtb_sample_tick_gen___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtb_sample_tick_gen___024root___ctor_var_reset\n"); );
    Vtb_sample_tick_gen__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    const uint64_t __VscopeHash = VL_MURMUR64_HASH(vlSelf->vlNamep);
    vlSelf->tb_sample_tick_gen__DOT__sys_clk = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 2309315097279690168ull);
    vlSelf->tb_sample_tick_gen__DOT__rst_n = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 13453599984049997840ull);
    vlSelf->tb_sample_tick_gen__DOT__audio_ce = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 8635555590133650951ull);
    vlSelf->tb_sample_tick_gen__DOT__pulse_count = 0;
    vlSelf->tb_sample_tick_gen__DOT__cycle_count = 0;
    vlSelf->tb_sample_tick_gen__DOT__prev_audio_ce = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 17352364087807901665ull);
    vlSelf->tb_sample_tick_gen__DOT__DUT__DOT__accumulator = VL_SCOPED_RAND_RESET_I(32, __VscopeHash, 1121893010070682909ull);
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VactTriggered[__Vi0] = 0;
    }
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VactTriggeredAcc[__Vi0] = 0;
    }
    vlSelf->__Vtrigprevexpr___TOP__tb_sample_tick_gen__DOT__sys_clk__0 = 0;
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VnbaTriggered[__Vi0] = 0;
    }
    vlSelf->__Vi = 0;
}
