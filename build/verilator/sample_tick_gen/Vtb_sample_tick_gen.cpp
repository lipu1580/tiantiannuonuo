// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Model implementation (design independent parts)

#include "Vtb_sample_tick_gen__pch.h"

//============================================================
// Constructors

Vtb_sample_tick_gen::Vtb_sample_tick_gen(VerilatedContext* _vcontextp__, const char* _vcname__)
    : VerilatedModel{*_vcontextp__}
    , vlSymsp{new Vtb_sample_tick_gen__Syms(contextp(), _vcname__, this)}
    , rootp{&(vlSymsp->TOP)}
{
    // Register model with the context
    contextp()->addModel(this);
}

Vtb_sample_tick_gen::Vtb_sample_tick_gen(const char* _vcname__)
    : Vtb_sample_tick_gen(Verilated::threadContextp(), _vcname__)
{
}

//============================================================
// Destructor

Vtb_sample_tick_gen::~Vtb_sample_tick_gen() {
    delete vlSymsp;
}

//============================================================
// Evaluation function

#ifdef VL_DEBUG
void Vtb_sample_tick_gen___024root___eval_debug_assertions(Vtb_sample_tick_gen___024root* vlSelf);
#endif  // VL_DEBUG
void Vtb_sample_tick_gen___024root___eval_static(Vtb_sample_tick_gen___024root* vlSelf);
void Vtb_sample_tick_gen___024root___eval_initial(Vtb_sample_tick_gen___024root* vlSelf);
void Vtb_sample_tick_gen___024root___eval_settle(Vtb_sample_tick_gen___024root* vlSelf);
void Vtb_sample_tick_gen___024root___eval(Vtb_sample_tick_gen___024root* vlSelf);

void Vtb_sample_tick_gen::eval_step() {
    VL_DEBUG_IF(VL_DBG_MSGF("+++++TOP Evaluate Vtb_sample_tick_gen::eval_step\n"); );
#ifdef VL_DEBUG
    // Debug assertions
    Vtb_sample_tick_gen___024root___eval_debug_assertions(&(vlSymsp->TOP));
#endif  // VL_DEBUG
    vlSymsp->__Vm_deleter.deleteAll();
    if (VL_UNLIKELY(!vlSymsp->__Vm_didInit)) {
        VL_DEBUG_IF(VL_DBG_MSGF("+ Initial\n"););
        Vtb_sample_tick_gen___024root___eval_static(&(vlSymsp->TOP));
        Vtb_sample_tick_gen___024root___eval_initial(&(vlSymsp->TOP));
        Vtb_sample_tick_gen___024root___eval_settle(&(vlSymsp->TOP));
        vlSymsp->__Vm_didInit = true;
    }
    VL_DEBUG_IF(VL_DBG_MSGF("+ Eval\n"););
    Vtb_sample_tick_gen___024root___eval(&(vlSymsp->TOP));
    // Evaluate cleanup
    Verilated::endOfEval(vlSymsp->__Vm_evalMsgQp);
}

//============================================================
// Events and timing
bool Vtb_sample_tick_gen::eventsPending() { return !vlSymsp->TOP.__VdlySched.empty() && !contextp()->gotFinish(); }

uint64_t Vtb_sample_tick_gen::nextTimeSlot() { return vlSymsp->TOP.__VdlySched.nextTimeSlot(); }

//============================================================
// Utilities

const char* Vtb_sample_tick_gen::name() const {
    return vlSymsp->name();
}

//============================================================
// Invoke final blocks

void Vtb_sample_tick_gen___024root___eval_final(Vtb_sample_tick_gen___024root* vlSelf);

VL_ATTR_COLD void Vtb_sample_tick_gen::final() {
    contextp()->executingFinal(true);
    Vtb_sample_tick_gen___024root___eval_final(&(vlSymsp->TOP));
    contextp()->executingFinal(false);
}

//============================================================
// Implementations of abstract methods from VerilatedModel

const char* Vtb_sample_tick_gen::hierName() const { return vlSymsp->name(); }
const char* Vtb_sample_tick_gen::modelName() const { return "Vtb_sample_tick_gen"; }
unsigned Vtb_sample_tick_gen::threads() const { return 1; }
void Vtb_sample_tick_gen::prepareClone() const { contextp()->prepareClone(); }
void Vtb_sample_tick_gen::atClone() const {
    contextp()->threadPoolpOnClone();
}
