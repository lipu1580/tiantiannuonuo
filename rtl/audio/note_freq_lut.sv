`timescale 1ns/1ns

module note_freq_lut #(
    parameter integer NOTE_W      = 7,      // 音符编号位宽
    parameter integer PHASE_W     = 32,     // DDS 相位累加器位宽
    parameter integer SAMPLE_RATE = 48_000  // 音频采样率
)(
    input  logic [NOTE_W-1:0]   note_id, // MIDI 音符编号，69 对应 A4
    input  logic [11:0]         pitch_bend, // 滑音输入，2048 为中心
    output logic [PHASE_W-1:0]  phase_increment // DDS 每采样周期的相位增量
);
    // 组合查表接口：note_id 改变后，phase_increment 在组合逻辑传播后更新。
    // MIDI 69=A4=440 Hz，音符频率遵循十二平均律：
    //     f(note) = 440 * 2 ** ((note - 69) / 12)
    // DDS 相位增量的计算公式为：
    //     phase_increment = round(f(note) * 2**PHASE_W / SAMPLE_RATE)
    //
    // 表中保存 frequency * 2**32，保留小数频率，避免先舍入到 0.01 Hz。
    // 每个表项都以常量调用下面的函数；综合时即可计算完，运行时只有查表。
    // PHASE_W 和 SAMPLE_RATE 改变时，表项会自动换算成对应的相位增量。
    // 注意 SAMPLE_RATE 必须等于实际 audio_ce 的平均频率，不是 sys_clk 频率。
    localparam logic [127:0] FREQUENCY_SCALE = 128'd1 << 32;
    localparam logic [127:0] DENOMINATOR = 128'(SAMPLE_RATE) * FREQUENCY_SCALE;

    function automatic logic [PHASE_W-1:0] make_phase_increment(
        input logic [63:0] frequency_q32
    );
        logic [127:0] numerator; // 加宽中间结果，避免相位缩放时溢出。
        begin
            numerator = 128'(frequency_q32) << PHASE_W;
            // 正数的四舍五入：(分子 + 分母 / 2) / 分母。
            make_phase_increment = PHASE_W'((numerator + DENOMINATOR / 2) / DENOMINATOR);
        end
    endfunction

    // 这些条件仅用于发现错误参数，不增加运行时的数据路径。
    initial begin
        if (NOTE_W < 7)
            $fatal(1, "NOTE_W must be at least 7 to represent MIDI 0..127");
        if (PHASE_W < 1 || PHASE_W > 64)
            $fatal(1, "PHASE_W must be in 1..64");
        if (SAMPLE_RATE <= 0)
            $fatal(1, "SAMPLE_RATE must be positive");
    end

    // 基础版保留滑音端口，但暂不使用 pitch_bend；中心值为 2048。
    // 没有时钟和输出寄存器，本模块不会增加一个时钟周期的延迟。
    always_comb begin : note_to_phase_increment
        case (note_id)
            NOTE_W'(0): phase_increment = make_phase_increment(64'd35114788961); // C-1, 8.175799 Hz
            NOTE_W'(1): phase_increment = make_phase_increment(64'd37202822971); // C#-1, 8.661957 Hz
            NOTE_W'(2): phase_increment = make_phase_increment(64'd39415017944); // D-1, 9.177024 Hz
            NOTE_W'(3): phase_increment = make_phase_increment(64'd41758756875); // D#-1, 9.722718 Hz
            NOTE_W'(4): phase_increment = make_phase_increment(64'd44241861775); // E-1, 10.300861 Hz
            NOTE_W'(5): phase_increment = make_phase_increment(64'd46872619776); // F-1, 10.913382 Hz
            NOTE_W'(6): phase_increment = make_phase_increment(64'd49659810789); // F#-1, 11.562326 Hz
            NOTE_W'(7): phase_increment = make_phase_increment(64'd52612736804); // G-1, 12.249857 Hz
            NOTE_W'(8): phase_increment = make_phase_increment(64'd55741252937); // G#-1, 12.978272 Hz
            NOTE_W'(9): phase_increment = make_phase_increment(64'd59055800320); // A-1, 13.750000 Hz
            NOTE_W'(10): phase_increment = make_phase_increment(64'd62567440947); // A#-1, 14.567618 Hz
            NOTE_W'(11): phase_increment = make_phase_increment(64'd66287894592); // B-1, 15.433853 Hz
            NOTE_W'(12): phase_increment = make_phase_increment(64'd70229577923); // C0, 16.351598 Hz
            NOTE_W'(13): phase_increment = make_phase_increment(64'd74405645942); // C#0, 17.323914 Hz
            NOTE_W'(14): phase_increment = make_phase_increment(64'd78830035887); // D0, 18.354048 Hz
            NOTE_W'(15): phase_increment = make_phase_increment(64'd83517513749); // D#0, 19.445436 Hz
            NOTE_W'(16): phase_increment = make_phase_increment(64'd88483723550); // E0, 20.601722 Hz
            NOTE_W'(17): phase_increment = make_phase_increment(64'd93745239553); // F0, 21.826764 Hz
            NOTE_W'(18): phase_increment = make_phase_increment(64'd99319621578); // F#0, 23.124651 Hz
            NOTE_W'(19): phase_increment = make_phase_increment(64'd105225473608); // G0, 24.499715 Hz
            NOTE_W'(20): phase_increment = make_phase_increment(64'd111482505874); // G#0, 25.956544 Hz
            NOTE_W'(21): phase_increment = make_phase_increment(64'd118111600640); // A0, 27.500000 Hz
            NOTE_W'(22): phase_increment = make_phase_increment(64'd125134881894); // A#0, 29.135235 Hz
            NOTE_W'(23): phase_increment = make_phase_increment(64'd132575789183); // B0, 30.867706 Hz
            NOTE_W'(24): phase_increment = make_phase_increment(64'd140459155845); // C1, 32.703196 Hz
            NOTE_W'(25): phase_increment = make_phase_increment(64'd148811291883); // C#1, 34.647829 Hz
            NOTE_W'(26): phase_increment = make_phase_increment(64'd157660071774); // D1, 36.708096 Hz
            NOTE_W'(27): phase_increment = make_phase_increment(64'd167035027499); // D#1, 38.890873 Hz
            NOTE_W'(28): phase_increment = make_phase_increment(64'd176967447100); // E1, 41.203445 Hz
            NOTE_W'(29): phase_increment = make_phase_increment(64'd187490479106); // F1, 43.653529 Hz
            NOTE_W'(30): phase_increment = make_phase_increment(64'd198639243156); // F#1, 46.249303 Hz
            NOTE_W'(31): phase_increment = make_phase_increment(64'd210450947215); // G1, 48.999429 Hz
            NOTE_W'(32): phase_increment = make_phase_increment(64'd222965011748); // G#1, 51.913087 Hz
            NOTE_W'(33): phase_increment = make_phase_increment(64'd236223201280); // A1, 55.000000 Hz
            NOTE_W'(34): phase_increment = make_phase_increment(64'd250269763788); // A#1, 58.270470 Hz
            NOTE_W'(35): phase_increment = make_phase_increment(64'd265151578367); // B1, 61.735413 Hz
            NOTE_W'(36): phase_increment = make_phase_increment(64'd280918311691); // C2, 65.406391 Hz
            NOTE_W'(37): phase_increment = make_phase_increment(64'd297622583766); // C#2, 69.295658 Hz
            NOTE_W'(38): phase_increment = make_phase_increment(64'd315320143548); // D2, 73.416192 Hz
            NOTE_W'(39): phase_increment = make_phase_increment(64'd334070054997); // D#2, 77.781746 Hz
            NOTE_W'(40): phase_increment = make_phase_increment(64'd353934894200); // E2, 82.406889 Hz
            NOTE_W'(41): phase_increment = make_phase_increment(64'd374980958211); // F2, 87.307058 Hz
            NOTE_W'(42): phase_increment = make_phase_increment(64'd397278486312); // F#2, 92.498606 Hz
            NOTE_W'(43): phase_increment = make_phase_increment(64'd420901894431); // G2, 97.998859 Hz
            NOTE_W'(44): phase_increment = make_phase_increment(64'd445930023495); // G#2, 103.826174 Hz
            NOTE_W'(45): phase_increment = make_phase_increment(64'd472446402560); // A2, 110.000000 Hz
            NOTE_W'(46): phase_increment = make_phase_increment(64'd500539527575); // A#2, 116.540940 Hz
            NOTE_W'(47): phase_increment = make_phase_increment(64'd530303156734); // B2, 123.470825 Hz
            NOTE_W'(48): phase_increment = make_phase_increment(64'd561836623382); // C3, 130.812783 Hz
            NOTE_W'(49): phase_increment = make_phase_increment(64'd595245167532); // C#3, 138.591315 Hz
            NOTE_W'(50): phase_increment = make_phase_increment(64'd630640287096); // D3, 146.832384 Hz
            NOTE_W'(51): phase_increment = make_phase_increment(64'd668140109995); // D#3, 155.563492 Hz
            NOTE_W'(52): phase_increment = make_phase_increment(64'd707869788401); // E3, 164.813778 Hz
            NOTE_W'(53): phase_increment = make_phase_increment(64'd749961916422); // F3, 174.614116 Hz
            NOTE_W'(54): phase_increment = make_phase_increment(64'd794556972624); // F#3, 184.997211 Hz
            NOTE_W'(55): phase_increment = make_phase_increment(64'd841803788861); // G3, 195.997718 Hz
            NOTE_W'(56): phase_increment = make_phase_increment(64'd891860046991); // G#3, 207.652349 Hz
            NOTE_W'(57): phase_increment = make_phase_increment(64'd944892805120); // A3, 220.000000 Hz
            NOTE_W'(58): phase_increment = make_phase_increment(64'd1001079055150); // A#3, 233.081881 Hz
            NOTE_W'(59): phase_increment = make_phase_increment(64'd1060606313468); // B3, 246.941651 Hz
            NOTE_W'(60): phase_increment = make_phase_increment(64'd1123673246764); // C4, 261.625565 Hz
            NOTE_W'(61): phase_increment = make_phase_increment(64'd1190490335065); // C#4, 277.182631 Hz
            NOTE_W'(62): phase_increment = make_phase_increment(64'd1261280574193); // D4, 293.664768 Hz
            NOTE_W'(63): phase_increment = make_phase_increment(64'd1336280219989); // D#4, 311.126984 Hz
            NOTE_W'(64): phase_increment = make_phase_increment(64'd1415739576801); // E4, 329.627557 Hz
            NOTE_W'(65): phase_increment = make_phase_increment(64'd1499923832845); // F4, 349.228231 Hz
            NOTE_W'(66): phase_increment = make_phase_increment(64'd1589113945249); // F#4, 369.994423 Hz
            NOTE_W'(67): phase_increment = make_phase_increment(64'd1683607577723); // G4, 391.995436 Hz
            NOTE_W'(68): phase_increment = make_phase_increment(64'd1783720093981); // G#4, 415.304698 Hz
            NOTE_W'(69): phase_increment = make_phase_increment(64'd1889785610240); // A4, 440.000000 Hz
            NOTE_W'(70): phase_increment = make_phase_increment(64'd2002158110301); // A#4, 466.163762 Hz
            NOTE_W'(71): phase_increment = make_phase_increment(64'd2121212626936); // B4, 493.883301 Hz
            NOTE_W'(72): phase_increment = make_phase_increment(64'd2247346493527); // C5, 523.251131 Hz
            NOTE_W'(73): phase_increment = make_phase_increment(64'd2380980670130); // C#5, 554.365262 Hz
            NOTE_W'(74): phase_increment = make_phase_increment(64'd2522561148385); // D5, 587.329536 Hz
            NOTE_W'(75): phase_increment = make_phase_increment(64'd2672560439979); // D#5, 622.253967 Hz
            NOTE_W'(76): phase_increment = make_phase_increment(64'd2831479153602); // E5, 659.255114 Hz
            NOTE_W'(77): phase_increment = make_phase_increment(64'd2999847665689); // F5, 698.456463 Hz
            NOTE_W'(78): phase_increment = make_phase_increment(64'd3178227890498); // F#5, 739.988845 Hz
            NOTE_W'(79): phase_increment = make_phase_increment(64'd3367215155446); // G5, 783.990872 Hz
            NOTE_W'(80): phase_increment = make_phase_increment(64'd3567440187962); // G#5, 830.609395 Hz
            NOTE_W'(81): phase_increment = make_phase_increment(64'd3779571220480); // A5, 880.000000 Hz
            NOTE_W'(82): phase_increment = make_phase_increment(64'd4004316220601); // A#5, 932.327523 Hz
            NOTE_W'(83): phase_increment = make_phase_increment(64'd4242425253871); // B5, 987.766603 Hz
            NOTE_W'(84): phase_increment = make_phase_increment(64'd4494692987054); // C6, 1046.502261 Hz
            NOTE_W'(85): phase_increment = make_phase_increment(64'd4761961340260); // C#6, 1108.730524 Hz
            NOTE_W'(86): phase_increment = make_phase_increment(64'd5045122296771); // D6, 1174.659072 Hz
            NOTE_W'(87): phase_increment = make_phase_increment(64'd5345120879958); // D#6, 1244.507935 Hz
            NOTE_W'(88): phase_increment = make_phase_increment(64'd5662958307205); // E6, 1318.510228 Hz
            NOTE_W'(89): phase_increment = make_phase_increment(64'd5999695331379); // F6, 1396.912926 Hz
            NOTE_W'(90): phase_increment = make_phase_increment(64'd6356455780995); // F#6, 1479.977691 Hz
            NOTE_W'(91): phase_increment = make_phase_increment(64'd6734430310891); // G6, 1567.981744 Hz
            NOTE_W'(92): phase_increment = make_phase_increment(64'd7134880375924); // G#6, 1661.218790 Hz
            NOTE_W'(93): phase_increment = make_phase_increment(64'd7559142440960); // A6, 1760.000000 Hz
            NOTE_W'(94): phase_increment = make_phase_increment(64'd8008632441202); // A#6, 1864.655046 Hz
            NOTE_W'(95): phase_increment = make_phase_increment(64'd8484850507742); // B6, 1975.533205 Hz
            NOTE_W'(96): phase_increment = make_phase_increment(64'd8989385974109); // C7, 2093.004522 Hz
            NOTE_W'(97): phase_increment = make_phase_increment(64'd9523922680519); // C#7, 2217.461048 Hz
            NOTE_W'(98): phase_increment = make_phase_increment(64'd10090244593542); // D7, 2349.318143 Hz
            NOTE_W'(99): phase_increment = make_phase_increment(64'd10690241759916); // D#7, 2489.015870 Hz
            NOTE_W'(100): phase_increment = make_phase_increment(64'd11325916614409); // E7, 2637.020455 Hz
            NOTE_W'(101): phase_increment = make_phase_increment(64'd11999390662757); // F7, 2793.825851 Hz
            NOTE_W'(102): phase_increment = make_phase_increment(64'd12712911561991); // F#7, 2959.955382 Hz
            NOTE_W'(103): phase_increment = make_phase_increment(64'd13468860621783); // G7, 3135.963488 Hz
            NOTE_W'(104): phase_increment = make_phase_increment(64'd14269760751848); // G#7, 3322.437581 Hz
            NOTE_W'(105): phase_increment = make_phase_increment(64'd15118284881920); // A7, 3520.000000 Hz
            NOTE_W'(106): phase_increment = make_phase_increment(64'd16017264882404); // A#7, 3729.310092 Hz
            NOTE_W'(107): phase_increment = make_phase_increment(64'd16969701015485); // B7, 3951.066410 Hz
            NOTE_W'(108): phase_increment = make_phase_increment(64'd17978771948217); // C8, 4186.009045 Hz
            NOTE_W'(109): phase_increment = make_phase_increment(64'd19047845361038); // C#8, 4434.922096 Hz
            NOTE_W'(110): phase_increment = make_phase_increment(64'd20180489187083); // D8, 4698.636287 Hz
            NOTE_W'(111): phase_increment = make_phase_increment(64'd21380483519831); // D#8, 4978.031740 Hz
            NOTE_W'(112): phase_increment = make_phase_increment(64'd22651833228818); // E8, 5274.040911 Hz
            NOTE_W'(113): phase_increment = make_phase_increment(64'd23998781325515); // F8, 5587.651703 Hz
            NOTE_W'(114): phase_increment = make_phase_increment(64'd25425823123982); // F#8, 5919.910763 Hz
            NOTE_W'(115): phase_increment = make_phase_increment(64'd26937721243566); // G8, 6271.926976 Hz
            NOTE_W'(116): phase_increment = make_phase_increment(64'd28539521503697); // G#8, 6644.875161 Hz
            NOTE_W'(117): phase_increment = make_phase_increment(64'd30236569763840); // A8, 7040.000000 Hz
            NOTE_W'(118): phase_increment = make_phase_increment(64'd32034529764809); // A#8, 7458.620184 Hz
            NOTE_W'(119): phase_increment = make_phase_increment(64'd33939402030969); // B8, 7902.132820 Hz
            NOTE_W'(120): phase_increment = make_phase_increment(64'd35957543896435); // C9, 8372.018090 Hz
            NOTE_W'(121): phase_increment = make_phase_increment(64'd38095690722077); // C#9, 8869.844191 Hz
            NOTE_W'(122): phase_increment = make_phase_increment(64'd40360978374166); // D9, 9397.272573 Hz
            NOTE_W'(123): phase_increment = make_phase_increment(64'd42760967039663); // D#9, 9956.063479 Hz
            NOTE_W'(124): phase_increment = make_phase_increment(64'd45303666457637); // E9, 10548.081821 Hz
            NOTE_W'(125): phase_increment = make_phase_increment(64'd47997562651029); // F9, 11175.303406 Hz
            NOTE_W'(126): phase_increment = make_phase_increment(64'd50851646247964); // F#9, 11839.821527 Hz
            NOTE_W'(127): phase_increment = make_phase_increment(64'd53875442487132); // G9, 12543.853951 Hz
            default: phase_increment = '0; // 超出 MIDI 0..127 或未知输入时返回 0。
        endcase
    end
endmodule
