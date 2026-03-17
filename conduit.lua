-- conduit
--
-- patch-programmable complex
-- oscillator with routing matrix
--
-- a small feedback network with
-- the right nonlinearities is
-- more alive than a massive patch.
--
-- E1: page
-- E2/E3: context-dependent
-- K2/K3: context-dependent
-- grid left: routing matrix
-- grid right: isomorphic keyboard
--
-- v0.1 @conduit

engine.name = "Conduit"

local musicutil = require "musicutil"

-- ── CONSTANTS ────────────────────────────────────────────

local MODULE_NAMES = {"OSC A", "OSC B", "FOLD", "FILT", "MOD"}
local MODULE_SHORT = {"oA", "oB", "fd", "fl", "md"}

-- routing amounts: quantized to 4 levels
-- every level sounds musical — no margin for error
local ROUTE_LEVELS = {0.0, 0.08, 0.25, 0.6}
local ROUTE_BRIGHT = {0, 4, 9, 15}

-- grid brightness vocabulary
local B = {
  OFF    = 0,
  GHOST  = 2,
  DIM    = 4,
  MID    = 8,
  BRIGHT = 12,
  FULL   = 15,
}

-- ── STATE ────────────────────────────────────────────────

local g = grid.connect()

local page = 1           -- 1=ROUTE, 2=MODULE, 3=MACRO
local selected_module = 1 -- 1-5
local macro_pair = 1      -- 1 = macros 1+2, 2 = macros 3+4

-- routing matrix: route_matrix[src][dst] = level index (1-4)
local route_matrix = {}
for src = 1, 5 do
  route_matrix[src] = {}
  for dst = 1, 5 do
    route_matrix[src][dst] = 1  -- level 1 = off
  end
end

-- macro values (0.0 – 1.0)
local macros = {0.0, 0.0, 0.0, 0.0}
local MACRO_NAMES = {"TEXTURE", "MOTION", "SPACE", "DENSITY"}

-- macro recording system
local macro_recording = {}
local is_recording = false
local recording_start_time = 0

-- keyboard state
local held_notes = {}
local root_note = 48  -- C3
local scale_name = "chromatic"
local scale_notes = {}

-- current playing note for screen display
local current_note = nil
local playing = false

-- screen redraw flag
local dirty = true

-- screen design system state
local beat_phase = 0.0      -- 0.0 to 1.0, pulses at beat rate
local popup_param = nil     -- transient parameter name
local popup_val = nil       -- transient parameter value (pre-formatted string)
local popup_time = 0        -- time remaining for popup display
local midi_activity_time = 0 -- time remaining for MIDI activity flash

-- grid modulation matrix: rows 5-8 (destinations), cols 1-4 (sources)
-- grid_mod_matrix[row - 4][col] = true if connection active
local grid_mod_matrix = {}
for row = 1, 4 do
  grid_mod_matrix[row] = {}
  for col = 1, 4 do
    grid_mod_matrix[row][col] = false
  end
end

local MOD_SOURCES = {"LFO1", "LFO2", "ENV", "Random"}  -- cols 1-4
local MOD_DESTS = {"OSC A freq", "OSC B freq", "Filter cutoff", "Fold amount"}  -- rows 5-8

-- ── TEMPLATES ────────────────────────────────────────────
-- each template is a curated starting point that sounds
-- immediately incredible. no bad sounds possible.

local templates = {
  -- 1: WEST COAST — Buchla brass, singing wavefolded tone
  {
    name = "WEST COAST",
    params = {
      osc_a_morph = 0.0, osc_b_morph = 0.0,
      osc_b_ratio = 3.0, osc_b_level = 0.4,
      fold_amt = 2.5, fold_sym = 0.5,
      cutoff = 4000, res = 0.2, filt_morph = 0.0,
      mod_rate = 4.5, mod_shape = 0.0, mod_depth = 0.5,
      atk = 0.005, dec = 0.4, sus = 0.6, rel = 0.5,
      verb_mix = 0.15,
    },
    routes = {
      {5, 3, 3}, -- mod → fold (moderate)
      {5, 4, 2}, -- mod → filt (subtle)
    }
  },
  -- 2: BERLIN — classic subtractive, detuned saw sweep
  {
    name = "BERLIN",
    params = {
      osc_a_morph = 0.66, osc_b_morph = 0.66,
      osc_b_ratio = 1.005, osc_b_level = 0.7,
      fold_amt = 0.5, fold_sym = 0.5,
      cutoff = 1200, res = 0.45, filt_morph = 0.0,
      mod_rate = 0.15, mod_shape = 0.0, mod_depth = 0.6,
      atk = 0.01, dec = 0.5, sus = 0.5, rel = 0.4,
      verb_mix = 0.1,
    },
    routes = {
      {5, 4, 4}, -- mod → filt (heavy)
    }
  },
  -- 3: CRYSTAL — high shimmer, bandpass sparkle
  {
    name = "CRYSTAL",
    params = {
      osc_a_morph = 0.33, osc_b_morph = 0.99,
      osc_b_ratio = 5.0, osc_b_level = 0.3,
      fold_amt = 2.0, fold_sym = 0.8,
      cutoff = 6000, res = 0.4, filt_morph = 0.5,
      mod_rate = 3.0, mod_shape = 0.33, mod_depth = 0.3,
      atk = 0.002, dec = 0.8, sus = 0.3, rel = 1.2,
      verb_mix = 0.25,
    },
    routes = {
      {5, 3, 2}, -- mod → fold (subtle)
      {2, 4, 2}, -- oscB → filt (subtle)
    }
  },
  -- 4: DRONE — slow evolving mass
  {
    name = "DRONE",
    params = {
      osc_a_morph = 0.0, osc_b_morph = 0.0,
      osc_b_ratio = 1.5, osc_b_level = 0.6,
      fold_amt = 2.0, fold_sym = 0.3,
      cutoff = 800, res = 0.55, filt_morph = 0.0,
      mod_rate = 0.08, mod_shape = 0.0, mod_depth = 0.7,
      atk = 2.0, dec = 1.0, sus = 0.9, rel = 3.0,
      verb_mix = 0.3,
    },
    routes = {
      {5, 4, 4}, -- mod → filt (heavy)
      {5, 3, 3}, -- mod → fold (moderate)
      {2, 1, 2}, -- oscB → oscA (subtle cross-mod)
    }
  },
  -- 5: PERC — metallic strike, inharmonic partials
  {
    name = "PERC",
    params = {
      osc_a_morph = 0.33, osc_b_morph = 0.33,
      osc_b_ratio = 2.76, osc_b_level = 0.5,
      fold_amt = 3.5, fold_sym = 0.5,
      cutoff = 3200, res = 0.6, filt_morph = 0.0,
      mod_rate = 18.0, mod_shape = 0.0, mod_depth = 0.0,
      atk = 0.001, dec = 0.18, sus = 0.0, rel = 0.3,
      verb_mix = 0.2,
    },
    routes = {
      {3, 4, 3}, -- fold → filt (moderate)
    }
  },
  -- 6: ACID — resonant squelch
  {
    name = "ACID",
    params = {
      osc_a_morph = 0.66, osc_b_morph = 0.66,
      osc_b_ratio = 1.0, osc_b_level = 0.0,
      fold_amt = 0.5, fold_sym = 0.5,
      cutoff = 500, res = 0.8, filt_morph = 0.0,
      mod_rate = 0.3, mod_shape = 0.66, mod_depth = 0.65,
      atk = 0.001, dec = 0.25, sus = 0.2, rel = 0.15,
      verb_mix = 0.08,
    },
    routes = {
      {5, 4, 4}, -- mod → filt (heavy)
    }
  },
  -- 7: GLASS — FM bell, pure partials decaying
  {
    name = "GLASS",
    params = {
      osc_a_morph = 0.0, osc_b_morph = 0.0,
      osc_b_ratio = 7.0, osc_b_level = 0.2,
      fold_amt = 0.8, fold_sym = 0.5,
      cutoff = 9000, res = 0.1, filt_morph = 0.0,
      mod_rate = 0.04, mod_shape = 0.0, mod_depth = 0.15,
      atk = 0.001, dec = 1.8, sus = 0.0, rel = 2.5,
      verb_mix = 0.3,
    },
    routes = {
      {2, 1, 3}, -- oscB → oscA pitch (moderate FM)
    }
  },
  -- 8: TANGLE — controlled chaos, everything feeds everything
  {
    name = "TANGLE",
    params = {
      osc_a_morph = 0.66, osc_b_morph = 0.99,
      osc_b_ratio = 3.14, osc_b_level = 0.5,
      fold_amt = 2.8, fold_sym = 0.4,
      cutoff = 2000, res = 0.45, filt_morph = 0.25,
      mod_rate = 3.5, mod_shape = 0.66, mod_depth = 0.45,
      atk = 0.01, dec = 0.5, sus = 0.6, rel = 0.8,
      verb_mix = 0.18,
    },
    routes = {
      {1, 3, 3}, -- oscA → fold (moderate)
      {2, 1, 2}, -- oscB → oscA pitch (subtle)
      {3, 4, 3}, -- fold → filt (moderate)
      {4, 2, 2}, -- filt → oscB ratio (subtle)
      {5, 3, 3}, -- mod → fold (moderate)
    }
  },
}

local selected_template = 1

-- ── MODULE PARAM DEFINITIONS ─────────────────────────────
-- each module has two encoder-accessible params

local module_params = {
  -- OSC A: morph + oscB mix level
  {
    {name = "morph", key = "osc_a_morph", min = 0, max = 0.99, fmt = "%.2f"},
    {name = "B level", key = "osc_b_level", min = 0, max = 1.0, fmt = "%.2f"},
  },
  -- OSC B: morph + ratio
  {
    {name = "morph", key = "osc_b_morph", min = 0, max = 0.99, fmt = "%.2f"},
    {name = "ratio", key = "osc_b_ratio", min = 0.5, max = 12.0, fmt = "%.2f"},
  },
  -- FOLD: amount + symmetry
  {
    {name = "amount", key = "fold_amt", min = 0.3, max = 8.0, fmt = "%.1f"},
    {name = "symmetry", key = "fold_sym", min = 0, max = 1.0, fmt = "%.2f"},
  },
  -- FILT: cutoff + resonance
  {
    {name = "cutoff", key = "cutoff", min = 20, max = 18000, fmt = "%.0f", exp = true},
    {name = "resonance", key = "res", min = 0, max = 0.95, fmt = "%.2f"},
  },
  -- MOD: rate + depth
  {
    {name = "rate", key = "mod_rate", min = 0.01, max = 50, fmt = "%.2f", exp = true},
    {name = "depth", key = "mod_depth", min = 0, max = 1.0, fmt = "%.2f"},
  },
}


-- ── HELPERS ──────────────────────────────────────────────

local function send_route(src, dst, level_idx)
  local idx = (src - 1) * 5 + (dst - 1)
  local amt = ROUTE_LEVELS[level_idx]
  engine.route(idx, amt)
end

local function send_param(key, val)
  local fn = engine[key]
  if fn then fn(val) end
end

local function get_param_val(key)
  return params:get(key)
end

local function build_scale()
  scale_notes = {}
  local notes = musicutil.generate_scale(0, scale_name, 10)
  for _, n in ipairs(notes) do
    scale_notes[n % 12] = true
  end
end

local function is_scale_note(midi_note)
  if scale_name == "chromatic" then return true end
  return scale_notes[midi_note % 12] == true
end

local function is_root_note(midi_note)
  return (midi_note % 12) == (root_note % 12)
end

-- isomorphic keyboard: +1 semitone per col right, +5 per row up
local function grid_to_note(x, y)
  return root_note + (x - 9) + (8 - y) * 5
end

local function note_on(note, vel)
  local freq = musicutil.note_num_to_freq(note)
  engine.note_on(freq, vel or 100)
  current_note = note
  playing = true
  midi_activity_time = 0.2
  dirty = true
end

local function note_off()
  engine.note_off()
  playing = false
  current_note = nil
  dirty = true
end

-- ── MACROS ───────────────────────────────────────────────
-- each macro smoothly controls multiple params at once.
-- one knob turn reshapes the entire sound.

local function apply_macro(idx, val)
  macros[idx] = util.clamp(val, 0, 1)

  if idx == 1 then
    -- TEXTURE: harmonic complexity
    -- sine/clean → rich/folded
    params:set("osc_a_morph", val * 0.8)
    params:set("fold_amt", 0.3 + val * 6.0)
    params:set("osc_b_level", val * 0.8)

  elseif idx == 2 then
    -- MOTION: modulation intensity
    -- static → heavily modulated
    params:set("mod_depth", val * 0.8)
    -- also push mod→filt and mod→fold routes
    local filt_lvl = val < 0.25 and 1 or (val < 0.5 and 2 or (val < 0.75 and 3 or 4))
    local fold_lvl = val < 0.5 and 1 or (val < 0.75 and 2 or 3)
    route_matrix[5][4] = filt_lvl
    route_matrix[5][3] = fold_lvl
    send_route(5, 4, filt_lvl)
    send_route(5, 3, fold_lvl)

  elseif idx == 3 then
    -- SPACE: wet/ambient
    -- dry/tight → washed/expansive
    params:set("verb_mix", val * 0.5)
    params:set("rel", 0.1 + val * 4.0)
    params:set("res", val * 0.6)

  elseif idx == 4 then
    -- DENSITY: harmonic density
    -- fundamental → complex partial cloud
    params:set("osc_b_ratio", 1.0 + val * 10.0)
    -- push oscB→oscA cross-mod
    local cross_lvl = val < 0.3 and 1 or (val < 0.6 and 2 or (val < 0.85 and 3 or 4))
    route_matrix[2][1] = cross_lvl
    send_route(2, 1, cross_lvl)
  end
  dirty = true
end

-- ── MACRO RECORDING ──────────────────────────────────────

local function start_macro_recording()
  is_recording = true
  recording_start_time = clock.get_beats()
  macro_recording = {}
  dirty = true
end

local function stop_macro_recording()
  is_recording = false
  dirty = true
end

local function playback_macro_recording()
  if #macro_recording == 0 then return end
  clock.run(function()
    for i, event in ipairs(macro_recording) do
      local wait_time = event.time - (macro_recording[i-1] and macro_recording[i-1].time or recording_start_time)
      clock.sleep(wait_time)
      apply_macro(event.macro, event.value)
    end
  end)
end

-- ── TEMPLATE LOADING ─────────────────────────────────────

local function load_template(idx)
  local t = templates[idx]
  if not t then return end

  selected_template = idx

  -- clear routing
  for src = 1, 5 do
    for dst = 1, 5 do
      route_matrix[src][dst] = 1
      send_route(src, dst, 1)
    end
  end

  -- apply params
  for key, val in pairs(t.params) do
    if params.lookup[key] then
      params:set(key, val)
    end
  end

  -- apply routes
  if t.routes then
    for _, r in ipairs(t.routes) do
      local src, dst, lvl = r[1], r[2], r[3]
      route_matrix[src][dst] = lvl
      send_route(src, dst, lvl)
    end
  end

  -- reset macros
  for i = 1, 4 do macros[i] = 0 end

  dirty = true
end


-- ── GRID ─────────────────────────────────────────────────
-- Layout (16×8):
--   cols 1-5, rows 1-5:  routing matrix
--   cols 1-4, rows 5-8:  modulation matrix
--   cols 1-5, row 7:     module focus selector
--   cols 1-8, row 8:     template selector
--   cols 9-16, rows 1-8: isomorphic keyboard

local function grid_redraw()
  g:all(0)

  -- ── Routing matrix (cols 1-5, rows 1-5) ──
  for src = 1, 5 do
    for dst = 1, 5 do
      local lvl = route_matrix[src][dst]
      g:led(dst, src, ROUTE_BRIGHT[lvl])
    end
  end

  -- ── Row 6: visual separator ──
  for x = 1, 5 do
    g:led(x, 6, B.GHOST)
  end

  -- ── Modulation matrix (cols 1-4, rows 5-8) ──
  -- Sources on cols 1-4: LFO1, LFO2, ENV, Random
  -- Destinations on rows 5-8: OSC A, OSC B, Filter, Fold
  for col = 1, 4 do
    for row = 5, 8 do
      local dest_idx = row - 4
      local is_active = grid_mod_matrix[dest_idx][col]
      g:led(col, row, is_active and B.BRIGHT or B.DIM)
    end
  end

  -- ── Module selector (row 7, cols 1-5) ──
  for i = 1, 5 do
    g:led(i, 7, i == selected_module and B.BRIGHT or B.DIM)
  end

  -- ── Template selector (row 8, cols 1-8) ──
  for i = 1, 8 do
    g:led(i, 8, i == selected_template and B.BRIGHT or B.DIM)
  end

  -- ── Keyboard (cols 9-16, rows 1-8) ──
  for x = 9, 16 do
    for y = 1, 8 do
      local note = grid_to_note(x, y)
      local bright = B.OFF

      -- scale highlighting
      if is_root_note(note) then
        bright = B.MID
      elseif is_scale_note(note) then
        bright = B.DIM
      end

      -- currently held notes
      if held_notes[note] then
        bright = B.FULL
      end

      g:led(x, y, bright)
    end
  end

  g:refresh()
end

g.key = function(x, y, z)
  -- ── Modulation matrix (cols 1-4, rows 5-8) ──
  if x >= 1 and x <= 4 and y >= 5 and y <= 8 then
    if z == 1 then
      local col = x
      local dest_idx = y - 4
      grid_mod_matrix[dest_idx][col] = not grid_mod_matrix[dest_idx][col]
      dirty = true
    end

  -- ── Routing matrix ──
  elseif x >= 1 and x <= 5 and y >= 1 and y <= 5 then
    if z == 1 then
      local src, dst = y, x
      local lvl = route_matrix[src][dst]
      lvl = (lvl % 4) + 1  -- cycle: 1→2→3→4→1
      route_matrix[src][dst] = lvl
      send_route(src, dst, lvl)
      dirty = true
    end

  -- ── Module selector ──
  elseif y == 7 and x >= 1 and x <= 5 then
    if z == 1 then
      selected_module = x
      page = 2  -- jump to module page
      dirty = true
    end

  -- ── Template selector ──
  elseif y == 8 and x >= 1 and x <= 8 then
    if z == 1 then
      load_template(x)
    end

  -- ── Keyboard ──
  elseif x >= 9 and x <= 16 and y >= 1 and y <= 8 then
    local note = grid_to_note(x, y)
    if z == 1 then
      held_notes[note] = true
      note_on(note, 100)
    else
      held_notes[note] = nil
      -- only note_off if no keys held
      local any_held = false
      for _ in pairs(held_notes) do any_held = true; break end
      if not any_held then
        note_off()
      else
        -- retrigger the most recent remaining held note
        for n, _ in pairs(held_notes) do
          note_on(n, 100)
          break
        end
      end
    end
  end

  grid_redraw()
end


-- ── SCREEN ───────────────────────────────────────────────

local function pulse_brightness()
  -- beat_phase 0.0-1.0, returns brightness 3-15
  local t = beat_phase
  if t < 0.5 then
    return 3 + t * 24
  else
    return 15 - (t - 0.5) * 24
  end
end

local function draw_status_strip()
  -- y 0-8: "CONDUIT" at level 4, page dots at level 12/3, beat pulse at x=124
  screen.level(4)
  screen.move(2, 7)
  screen.text("CONDUIT")

  -- page indicator dots: ROUTE / MODULE / MACRO
  for i = 1, 3 do
    screen.level(i == page and 12 or 3)
    screen.circle(58 + (i - 1) * 6, 4, 1)
    screen.fill()
  end

  -- template name at level 6
  screen.level(6)
  screen.move(65, 7)
  screen.text_center(templates[selected_template].name)

  -- beat pulse dot at x=124
  local pulse_level = math.floor(pulse_brightness())
  screen.level(pulse_level)
  screen.circle(124, 4, 1)
  screen.fill()

  -- separator line
  screen.level(2)
  screen.move(0, 9)
  screen.line(128, 9)
  screen.stroke()
end

-- Page-draw functions defined BEFORE draw_live_zone so they are in scope
-- when draw_live_zone is compiled (Lua 5.3 forward-reference rule).

local function draw_route_page()
  -- ROUTE: sources on left (level 5), destinations on top (level 5)
  -- Active connections as bright points (level 12-15)
  -- Inactive intersections at level 2
  -- Selected connection at level 15
  
  local ox, oy = 12, 15
  local cell = 9

  -- column labels (destinations) at level 5
  screen.level(5)
  for i = 1, 5 do
    screen.move(ox + (i - 1) * cell + cell / 2, oy - 4)
    screen.text_center(MODULE_SHORT[i])
  end

  -- matrix
  for src = 1, 5 do
    -- row label (source) at level 5
    screen.level(5)
    screen.move(ox - 4, oy + (src - 1) * cell + cell / 2 + 2)
    screen.text_right(MODULE_SHORT[src])

    for dst = 1, 5 do
      local lvl = route_matrix[src][dst]
      local cx = ox + (dst - 1) * cell + cell / 2
      local cy = oy + (src - 1) * cell + cell / 2

      if lvl == 1 then
        -- inactive at level 2
        screen.level(2)
        screen.pixel(cx, cy)
        screen.fill()
      else
        -- active: brightness based on level
        screen.level(9 + lvl * 2)
        screen.circle(cx, cy, lvl - 0.5)
        screen.fill()
      end
    end
  end
end

local function draw_module_page()
  -- MODULE: parameter bars. Selected param at level 15, others at level 8. Labels at level 5.
  local mp = module_params[selected_module]

  -- module name header
  screen.level(12)
  screen.move(65, 18)
  screen.text_center(MODULE_NAMES[selected_module])

  for i = 1, 2 do
    local p = mp[i]
    local val = params:get(p.key)
    local y_pos = 28 + (i - 1) * 16

    -- param name at level 5
    screen.level(5)
    screen.move(2, y_pos - 2)
    screen.text(p.name)

    -- value at level 15
    screen.level(15)
    screen.move(126, y_pos - 2)
    screen.text_right(string.format(p.fmt, val))

    -- horizontal bar
    local bar_max = p.max
    local bar_val = val
    if p.exp then
      bar_val = math.log(val) / math.log(bar_max)
      bar_max = 1
    end
    
    -- bar background at level 2
    screen.level(2)
    screen.rect(2, y_pos + 1, 124, 4)
    screen.fill()
    
    -- bar fill at level 8
    screen.level(8)
    local fill = util.clamp(bar_val / bar_max, 0, 1) * 124
    screen.rect(2, y_pos + 1, fill, 4)
    screen.fill()
  end
end

local function draw_macro_page()
  -- MACRO: fader positions as vertical bars. Active at level 15, others at level 8.
  -- If recording active, show "REC" pulsing at level 12.
  local start_idx = (macro_pair - 1) * 2 + 1

  -- title
  screen.level(12)
  screen.move(65, 18)
  screen.text_center("MACROS")

  for i = 0, 1 do
    local idx = start_idx + i
    local x_pos = 20 + i * 50

    -- macro name at level 5
    screen.level(5)
    screen.move(x_pos, 28)
    screen.text_center(MACRO_NAMES[idx])

    -- value at level 15
    screen.level(15)
    screen.move(x_pos, 37)
    screen.text_center(string.format("%.0f%%", macros[idx] * 100))

    -- vertical bar background at level 2
    screen.level(2)
    screen.rect(x_pos - 3, 42, 6, 8)
    screen.fill()

    -- vertical bar fill at level 8 or 15
    screen.level(8)
    local fill_height = macros[idx] * 8
    screen.rect(x_pos - 3, 42 + (8 - fill_height), 6, fill_height)
    screen.fill()
  end

  -- recording status at level 12 pulsing
  if is_recording then
    screen.level(math.floor(pulse_brightness()))
    screen.move(65, 45)
    screen.text_center("REC")
  end
end

local function draw_live_zone()
  if page == 1 then
    draw_route_page()
  elseif page == 2 then
    draw_module_page()
  elseif page == 3 then
    draw_macro_page()
  end
end

local function draw_context_bar()
  -- y 53-58: template name (level 5), MIDI channel (level 4), active note count (level 6)
  screen.level(2)
  screen.move(0, 52)
  screen.line(128, 52)
  screen.stroke()

  screen.level(5)
  screen.move(2, 58)
  screen.text(templates[selected_template].name)

  screen.level(4)
  screen.move(65, 58)
  screen.text_center("CH: 1")

  if playing then
    screen.level(6)
    screen.move(126, 58)
    screen.text_right(musicutil.note_num_to_name(current_note, true))
  end
end

local function draw_midi_activity()
  -- small dot near context bar that flashes level 12 when notes pass through
  if midi_activity_time > 0 then
    screen.level(12)
    screen.circle(115, 54, 1)
    screen.fill()
  end
end

local function draw_transient_popup()
  -- enc() triggers popup for 0.8s at center of screen
  -- popup_val holds a pre-formatted display string
  if popup_time > 0 and popup_param then
    screen.level(12)
    screen.move(65, 25)
    screen.text_center(popup_param)
    if popup_val then
      screen.level(15)
      screen.move(65, 35)
      screen.text_center(tostring(popup_val))
    end
  end
end

function redraw()
  screen.clear()
  
  -- draw all screen zones
  draw_status_strip()
  draw_live_zone()
  draw_context_bar()
  draw_midi_activity()
  draw_transient_popup()

  screen.update()
end


-- ── ENCODERS & KEYS ──────────────────────────────────────

function enc(n, d)
  if n == 1 then
    -- page select
    page = util.clamp(page + (d > 0 and 1 or -1), 1, 3)
    popup_param = {"ROUTE", "MODULE", "MACRO"}[page]
    popup_val = nil  -- page name shown in popup_param; no numeric value
    popup_time = 0.8

  elseif page == 2 then
    -- module params
    local mp = module_params[selected_module]
    local p_idx = n - 1  -- E2 → param 1, E3 → param 2
    local p = mp[p_idx]
    if p then
      local val = params:get(p.key)
      local step
      if p.exp then
        step = val * 0.02 * (d > 0 and 1 or -1)
      else
        step = (p.max - p.min) / 100 * d
      end
      local new_val = util.clamp(val + step, p.min, p.max)
      params:set(p.key, new_val)
      popup_param = p.name
      popup_val = string.format(p.fmt, new_val)  -- pre-format for safe display
      popup_time = 0.8
    end

  elseif page == 3 then
    -- macros
    local idx = (macro_pair - 1) * 2 + (n - 1)  -- E2 → macro 1or3, E3 → macro 2or4
    if idx >= 1 and idx <= 4 then
      if is_recording then
        -- while recording, capture macro changes
        table.insert(macro_recording, {
          time = clock.get_beats(),
          macro = idx,
          value = macros[idx] + d * 0.01
        })
      end
      apply_macro(idx, macros[idx] + d * 0.01)
      popup_param = MACRO_NAMES[idx]
      popup_val = string.format("%.0f%%", macros[idx] * 100)  -- pre-format
      popup_time = 0.8
    end
  end

  dirty = true
end

function key(n, z)
  if z == 0 then return end

  if page == 1 then
    -- K2/K3 navigate modules on route page
    if n == 2 then
      selected_module = util.clamp(selected_module - 1, 1, 5)
    elseif n == 3 then
      selected_module = util.clamp(selected_module + 1, 1, 5)
    end

  elseif page == 2 then
    -- K2/K3 cycle modules
    if n == 2 then
      selected_module = util.clamp(selected_module - 1, 1, 5)
    elseif n == 3 then
      selected_module = util.clamp(selected_module + 1, 1, 5)
    end

  elseif page == 3 then
    -- K2+K3: start/stop macro recording
    if n == 2 or n == 3 then
      if is_recording then
        stop_macro_recording()
      else
        start_macro_recording()
      end
    end
  end

  dirty = true
end


-- ── MIDI ─────────────────────────────────────────────────

local midi_device

local function midi_event(data)
  local msg = midi.to_msg(data)
  if msg.type == "note_on" and msg.vel > 0 then
    note_on(msg.note, msg.vel)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    note_off()
  end
end


-- ── INIT ─────────────────────────────────────────────────

function init()

  -- ── parameters ──

  params:add_separator("CONDUIT")

  params:add_group("OSC A", 1)
  params:add_control("osc_a_morph", "morph",
    controlspec.new(0, 0.99, 'lin', 0.01, 0.0))
  params:set_action("osc_a_morph", function(v) engine.osc_a_morph(v); dirty = true end)

  params:add_group("OSC B", 3)
  params:add_control("osc_b_morph", "morph",
    controlspec.new(0, 0.99, 'lin', 0.01, 0.0))
  params:set_action("osc_b_morph", function(v) engine.osc_b_morph(v); dirty = true end)

  params:add_control("osc_b_ratio", "ratio",
    controlspec.new(0.5, 12.0, 'lin', 0.01, 2.0))
  params:set_action("osc_b_ratio", function(v) engine.osc_b_ratio(v); dirty = true end)

  params:add_control("osc_b_level", "B level",
    controlspec.new(0, 1.0, 'lin', 0.01, 0.5))
  params:set_action("osc_b_level", function(v) engine.osc_b_level(v); dirty = true end)

  params:add_group("FOLD", 2)
  params:add_control("fold_amt", "amount",
    controlspec.new(0.3, 8.0, 'lin', 0.01, 1.5))
  params:set_action("fold_amt", function(v) engine.fold_amt(v); dirty = true end)

  params:add_control("fold_sym", "symmetry",
    controlspec.new(0, 1.0, 'lin', 0.01, 0.5))
  params:set_action("fold_sym", function(v) engine.fold_sym(v); dirty = true end)

  params:add_group("FILTER", 3)
  params:add_control("cutoff", "cutoff",
    controlspec.new(20, 18000, 'exp', 0, 2400, "hz"))
  params:set_action("cutoff", function(v) engine.cutoff(v); dirty = true end)

  params:add_control("res", "resonance",
    controlspec.new(0, 0.95, 'lin', 0.01, 0.25))
  params:set_action("res", function(v) engine.res(v); dirty = true end)

  params:add_control("filt_morph", "morph (LP>BP>HP)",
    controlspec.new(0, 0.99, 'lin', 0.01, 0.0))
  params:set_action("filt_morph", function(v) engine.filt_morph(v); dirty = true end)

  params:add_group("MOD", 3)
  params:add_control("mod_rate", "rate",
    controlspec.new(0.01, 50, 'exp', 0, 2.0, "hz"))
  params:set_action("mod_rate", function(v) engine.mod_rate(v); dirty = true end)

  params:add_control("mod_shape", "shape",
    controlspec.new(0, 0.99, 'lin', 0.01, 0.0))
  params:set_action("mod_shape", function(v) engine.mod_shape(v); dirty = true end)

  params:add_control("mod_depth", "depth",
    controlspec.new(0, 1.0, 'lin', 0.01, 0.5))
  params:set_action("mod_depth", function(v) engine.mod_depth(v); dirty = true end)

  params:add_group("ENVELOPE", 4)
  params:add_control("atk", "attack",
    controlspec.new(0.001, 4.0, 'exp', 0, 0.005, "s"))
  params:set_action("atk", function(v) engine.atk(v); dirty = true end)

  params:add_control("dec", "decay",
    controlspec.new(0.01, 4.0, 'exp', 0, 0.3, "s"))
  params:set_action("dec", function(v) engine.dec(v); dirty = true end)

  params:add_control("sus", "sustain",
    controlspec.new(0, 1.0, 'lin', 0.01, 0.7))
  params:set_action("sus", function(v) engine.sus(v); dirty = true end)

  params:add_control("rel", "release",
    controlspec.new(0.01, 8.0, 'exp', 0, 0.6, "s"))
  params:set_action("rel", function(v) engine.rel(v); dirty = true end)

  params:add_group("OUTPUT", 2)
  params:add_control("pan", "pan",
    controlspec.new(-1, 1, 'lin', 0.01, 0))
  params:set_action("pan", function(v) engine.pan(v); dirty = true end)

  params:add_control("verb_mix", "reverb",
    controlspec.new(0, 1, 'lin', 0.01, 0.12))
  params:set_action("verb_mix", function(v) engine.verb_mix(v); dirty = true end)

  params:add_group("KEYBOARD", 2)
  params:add_option("scale", "scale",
    {"chromatic", "major", "minor", "dorian", "mixolydian",
     "pentatonic", "minor pentatonic", "blues"}, 1)
  params:set_action("scale", function(v)
    local names = {"chromatic", "major", "minor", "dorian", "mixolydian",
      "pentatonic", "minor pentatonic", "blues"}
    scale_name = names[v]
    build_scale()
    dirty = true
  end)

  params:add_number("root", "root note", 0, 127, 48)
  params:set_action("root", function(v)
    root_note = v
    build_scale()
    dirty = true
  end)

  -- ── build scale ──
  build_scale()

  -- ── MIDI ──
  midi_device = midi.connect(1)
  midi_device.event = midi_event

  -- ── load default template ──
  load_template(1)

  -- ── screen refresh clock at ~12fps with beat pulse ──
  clock.run(function()
    while true do
      clock.sleep(1/12)
      beat_phase = (beat_phase + 1/12 / 2) % 1.0  -- pulse cycle ~2 seconds
      popup_time = math.max(0, popup_time - 1/12)
      midi_activity_time = math.max(0, midi_activity_time - 1/12)
      if dirty then
        redraw()
        grid_redraw()
        dirty = false
      end
    end
  end)
end

function cleanup()
  clock.cancel_all()
  if m then
    for ch = 1, 16 do
      m:cc(123, 0, ch)
      m:cc(120, 0, ch)
    end
  end
end
