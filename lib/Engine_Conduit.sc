// Engine_Conduit.sc
// A patch-programmable complex oscillator for norns
//
// Architecture: 5 modules in a configurable feedback network
//   0: OSC A  — morphable primary oscillator (sin > tri > saw > pulse)
//   1: OSC B  — ratio-locked secondary oscillator
//   2: FOLD   — sinusoidal wavefolder (Buchla/Serge inspired)
//   3: FILT   — morphable resonant filter (LP > BP > HP)
//   4: MOD    — shape-morphable modulator (LFO range)
//
// Routing matrix: any module's output can modulate any module's
// primary parameter. 25 cross-points, each 0.0–1.0.
// Nonlinearities (tanh) in every feedback path keep it stable.
//
// Design philosophy: "no margin for error" — every parameter range
// is tuned so the system always sounds musical.

Engine_Conduit : CroneEngine {

  var voice;
  var <paramDict;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {

    // ── Persistent parameter storage ──────────────────────────
    // Values survive across notes; applied to each new voice.

    paramDict = Dictionary.new;

    // Oscillator A
    paramDict.put(\osc_a_morph, 0.0);

    // Oscillator B
    paramDict.put(\osc_b_morph, 0.0);
    paramDict.put(\osc_b_ratio, 2.0);
    paramDict.put(\osc_b_level, 0.5);

    // Wavefolder
    paramDict.put(\fold_amt, 1.5);
    paramDict.put(\fold_sym, 0.5);

    // Filter
    paramDict.put(\cutoff, 2400.0);
    paramDict.put(\res, 0.25);
    paramDict.put(\filt_morph, 0.0);

    // Modulator
    paramDict.put(\mod_rate, 2.0);
    paramDict.put(\mod_shape, 0.0);
    paramDict.put(\mod_depth, 0.5);

    // Envelope
    paramDict.put(\atk, 0.005);
    paramDict.put(\dec, 0.3);
    paramDict.put(\sus, 0.7);
    paramDict.put(\rel, 0.6);

    // Output
    paramDict.put(\pan, 0.0);
    paramDict.put(\verb_mix, 0.12);

    // Routing matrix (25 cross-points, all off)
    25.do { |i| paramDict.put(("r" ++ i).asSymbol, 0.0) };


    // ── SynthDef ──────────────────────────────────────────────

    SynthDef(\conduit_voice, {

      arg out=0, freq=220, gate=1, amp=0.5,
          // oscillators
          osc_a_morph=0.0,
          osc_b_morph=0.0, osc_b_ratio=2.0, osc_b_level=0.5,
          // wavefolder
          fold_amt=1.5, fold_sym=0.5,
          // filter
          cutoff=2400, res=0.25, filt_morph=0.0,
          // modulator
          mod_rate=2.0, mod_shape=0.0, mod_depth=0.5,
          // envelope
          atk=0.005, dec=0.3, sus=0.7, rel=0.6,
          // output
          pan=0, verb_mix=0.12,
          // routing matrix (flattened 5x5: index = src*5 + dst)
          r0=0,r1=0,r2=0,r3=0,r4=0,
          r5=0,r6=0,r7=0,r8=0,r9=0,
          r10=0,r11=0,r12=0,r13=0,r14=0,
          r15=0,r16=0,r17=0,r18=0,r19=0,
          r20=0,r21=0,r22=0,r23=0,r24=0;

      // --- all var declarations up front ---
      var env, prev;
      var m0, m1, m2, m3, m4;
      var freqA, oscA, freqB, oscB;
      var foldIn, foldDepth, folded;
      var cut, rq, lpf, bpf, hpf, filtered;
      var mrate, modulator;
      var sig, dry, verb;

      // ── Envelope ──
      env = EnvGen.kr(
        Env.adsr(atk, dec, sus, rel, curve: -3),
        gate,
        doneAction: Done.freeSelf
      );

      // ── Feedback (one block delay) ──
      prev = LocalIn.ar(5);

      // ── Routing Matrix ──
      // m[dest] = sum of (prev[src] * route[src][dest])
      // Destination 0 = OSC A pitch, 1 = OSC B ratio,
      // 2 = fold depth, 3 = cutoff, 4 = mod rate
      m0 = (prev[0]*r0)  + (prev[1]*r5)  + (prev[2]*r10) + (prev[3]*r15) + (prev[4]*r20);
      m1 = (prev[0]*r1)  + (prev[1]*r6)  + (prev[2]*r11) + (prev[3]*r16) + (prev[4]*r21);
      m2 = (prev[0]*r2)  + (prev[1]*r7)  + (prev[2]*r12) + (prev[3]*r17) + (prev[4]*r22);
      m3 = (prev[0]*r3)  + (prev[1]*r8)  + (prev[2]*r13) + (prev[3]*r18) + (prev[4]*r23);
      m4 = (prev[0]*r4)  + (prev[1]*r9)  + (prev[2]*r14) + (prev[3]*r19) + (prev[4]*r24);

      // ── MODULE 0 : OSC A ──────────────────────────
      // Morphable waveform: sin(0) → tri(0.33) → saw(0.66) → pulse(1)
      // Modulation target: pitch (±2 octaves, musically scaled)
      freqA = freq * (2.pow(m0.clip(-1, 1) * 2));
      oscA = SelectX.ar(osc_a_morph.clip(0, 0.99) * 3, [
        SinOsc.ar(freqA),
        LFTri.ar(freqA),
        Saw.ar(freqA),
        Pulse.ar(freqA, 0.5)
      ]);

      // ── MODULE 1 : OSC B ──────────────────────────
      // Ratio-locked to A. Mod target: ratio (±50%, always harmonic-ish)
      freqB = freq * (osc_b_ratio * (1 + (m1.clip(-1, 1) * 0.5)));
      oscB = SelectX.ar(osc_b_morph.clip(0, 0.99) * 3, [
        SinOsc.ar(freqB),
        LFTri.ar(freqB),
        Saw.ar(freqB),
        Pulse.ar(freqB, 0.5)
      ]);

      // ── MODULE 2 : WAVEFOLDER ─────────────────────
      // Sinusoidal folding: input.sin creates harmonic overtones
      // without the harshness of hard clipping.
      // Mod target: fold depth
      foldIn = oscA + (oscB * osc_b_level);
      foldDepth = (fold_amt + (m2.clip(-1, 1) * 3)).clip(0.3, 8);
      // .sin wavefold — the Serge/Buchla sweet spot
      folded = (foldIn * foldDepth).sin;
      // Symmetry: blend between bipolar fold and rectified fold
      folded = XFade2.ar(
        folded,
        (folded.abs * 2) - 1,
        fold_sym.linlin(0, 1, -1, 1)
      );

      // ── MODULE 3 : FILTER ─────────────────────────
      // Morphable LP→BP→HP. Mod target: cutoff (±4 octaves)
      cut = (cutoff * (2.pow(m3.clip(-1, 1) * 4))).clip(20, 18000);
      rq = res.linlin(0, 1, 1.0, 0.08);
      lpf = RLPF.ar(folded, cut, rq);
      bpf = BPF.ar(folded, cut, rq);
      hpf = RHPF.ar(folded, cut, rq);
      filtered = SelectX.ar(filt_morph.clip(0, 0.99) * 2, [lpf, bpf, hpf]);

      // ── MODULE 4 : MODULATOR ──────────────────────
      // LFO with shape morph. Mod target: rate (±2x)
      mrate = (mod_rate * (1 + (m4.clip(-1, 1) * 2))).clip(0.01, 50);
      modulator = SelectX.ar(mod_shape.clip(0, 0.99) * 3, [
        SinOsc.ar(mrate),
        LFTri.ar(mrate),
        LFSaw.ar(mrate),
        LFPulse.ar(mrate, 0, 0.5, 2, -1)
      ]) * mod_depth;

      // ── Feedback outputs ──────────────────────────
      // tanh on every path: the system CANNOT explode
      LocalOut.ar([
        oscA.tanh,
        oscB.tanh,
        folded.tanh,
        filtered.tanh,
        modulator
      ]);

      // ── Final output ──────────────────────────────
      sig = filtered * env * amp;
      sig = sig.tanh;  // warm saturation, never clips

      dry = Pan2.ar(sig, pan);
      verb = FreeVerb2.ar(dry[0], dry[1],
        verb_mix.clip(0, 1), 0.8, 0.4);
      sig = dry + verb;

      Out.ar(out, LeakDC.ar(sig));

    }).add;


    // ── Commands ──────────────────────────────────────────────

    // Note control
    this.addCommand("note_on", "ff", { arg msg;
      var args;
      if(voice.notNil, { voice.free });
      args = [
        \out, context.out_b,
        \freq, msg[1],
        \amp, msg[2].linlin(0, 127, 0, 0.6),
        \gate, 1
      ];
      paramDict.keysValuesDo { |k, v| args = args ++ [k, v] };
      voice = Synth(\conduit_voice, args, context.xg);
    });

    this.addCommand("note_off", "", {
      if(voice.notNil, { voice.set(\gate, 0) });
    });

    // Module parameter commands (stored + sent to active voice)
    [\osc_a_morph,
     \osc_b_morph, \osc_b_ratio, \osc_b_level,
     \fold_amt, \fold_sym,
     \cutoff, \res, \filt_morph,
     \mod_rate, \mod_shape, \mod_depth,
     \atk, \dec, \sus, \rel,
     \pan, \verb_mix
    ].do { |name|
      this.addCommand(name.asString, "f", { arg msg;
        paramDict.put(name, msg[1]);
        if(voice.notNil, { voice.set(name, msg[1]) });
      });
    };

    // Routing matrix: route(index, amount)
    //   index = src * 5 + dst (0–24)
    //   amount = 0.0–1.0
    this.addCommand("route", "if", { arg msg;
      var idx, amt, key;
      idx = msg[1].asInteger;
      amt = msg[2];
      key = ("r" ++ idx).asSymbol;
      paramDict.put(key, amt);
      if(voice.notNil, { voice.set(key, amt) });
    });
  }

  free {
    if(voice.notNil, { voice.free; voice = nil });
  }
}
