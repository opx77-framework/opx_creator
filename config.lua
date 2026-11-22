Config = {}

-- Locale file used for player-facing text: 'auto' follows the game language, or 'en' / 'fr'.
Config.locale = 'auto'

-- Where option names come from: 'game' = the game's catalogue (in the game's language), 'locale' = the
-- `slot_*` names of locales/<lang>.json first (the catalogue for the slots they leave out), 'auto' = 'game'
-- when Config.locale is 'auto' (same language as the game), else 'locale' (a forced locale stays consistent).
Config.optionLabels = 'auto'

-- Staff command that opens the creator in edit mode (`creator [playerId] [scope|close]`). Restricted: grant the
-- ACL right `command.<name>` in acl.jsonc. false = no command. Players have no command (no free re-customization).
Config.command = 'creator'

-- The categories (rail entries after Profile), in order. Each lists the catalogue `uiSlot`s it shows (Open77.body.catalog):
-- the option of each slot that is active for the current choices. `shot` picks the camera framing.
Config.categories = {
    { id = 'body', shot = 'body', slots = {
        'skin_color', 'skin_type_switcher', 'breast', 'nipples_switcher', 'body_tattoo_switcher',
        'body_scars_switcher', 'nails_l', 'nails_color' } },
    { id = 'face', shot = 'face', slots = {
        'eyes', 'nose', 'mouth', 'jaw', 'ear', 'teeth', 'scars', 'cyberware_switcher' } },
    { id = 'eyes', shot = 'eyes', slots = {
        'eyes_color', 'eyebrows', 'eyebrows_color', 'eyelash_color' } },
    { id = 'hair', shot = 'hair', slots = {
        'hairstyle', 'hair_color', 'beard', 'beard_part', 'beard_color' } },
    { id = 'makeup', shot = 'face', slots = {
        'makeupEyes', 'makeupEyes_color', 'makeupLips_type', 'makeupLips', 'makeupLips_color',
        'makeupCheeks', 'makeupCheeks_color', 'makeupPimples', 'makeupPimples_color' } },
    { id = 'marks', shot = 'face', slots = {
        'facial_tattoo_switcher', 'piercings', 'piercings_color' } },
    -- Clothing (`garments = true`): `slots` are equipment slots, listed by the skin provider (opx_core
    -- Config.providers.skin). Without a running skin provider these entries are not shown.
    { id = 'clothes', shot = 'body', garments = true, slots = { 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' } },
    { id = 'headwear', shot = 'face', garments = true, slots = { 'Head', 'Face' } },
}

-- Scopes: named sets of rail entries a caller opens with `options.scope` (rail order kept). false = every
-- entry. A wardrobe is the creator in the 'clothing' scope. Without 'profile' the body type cannot change.
-- Add your own (e.g. `piercer = { 'marks' }`); an unknown scope is refused ('invalid_options').
Config.scopes = {
    full = false,
    clothing = { 'clothes', 'headwear' },
    barber = { 'hair', 'makeup' },
    surgery = { 'body', 'face', 'eyes' },
    tattoo = { 'marks' },
}

-- Clothing. `starter` = what a character with no clothes at all wears when a 'creation' session opens (by
-- body type, equipment slot = item record); false = none. `bigStep` = garments skipped by Shift + Left / Right.
Config.clothing = {
    starter = {
        male = { InnerChest = 'Items.TShirt_01_basic_01', Legs = 'Items.Pants_01_basic_01', Feet = 'Items.CasualShoes_01_basic_01' },
        female = { InnerChest = 'Items.TShirt_01_basic_01', Legs = 'Items.Pants_01_basic_01', Feet = 'Items.CasualShoes_01_basic_01' },
    },
    bigStep = 10,
}

-- Camera shots in the player's own frame, metres: `distance` in front, camera `height`, `look` = height it
-- aims at, `side` = sideways offset that centres the character between the panels, `fov` in degrees.
Config.shots = {
    body = { distance = 2.55, height = 1.15, look = 0.98, side = 0.06, fov = 46 },
    face = { distance = 1.05, height = 1.67, look = 1.62, side = 0.02, fov = 34 },
    eyes = { distance = 0.72, height = 1.69, look = 1.66, side = 0.012, fov = 30 },
    hair = { distance = 1.25, height = 1.76, look = 1.66, side = 0.025, fov = 36 },
}

-- Camera travel between shots (a crane move, not a cut) and the free controls.
Config.camera = {
    travelSeconds = { min = 0.85, max = 1.5 },  -- travel time, by how far the next shot is
    swingDegrees = 15,      -- sideways swing around the character during a travel (0 = straight)
    liftRatio = 0.14,       -- pull back in the middle of a travel, share of the distance covered
    intro = { seconds = 1.9, distance = 1.4, height = 0.28, angle = -26 }, -- the opening move in
    turnSpeed = 110,        -- degrees per second while Q / E are held
    zoomStep = 0.12,        -- distance factor per mouse wheel notch
    zoomRange = { 0.5, 1.7 }, -- closest / furthest zoom factor
    dragDegrees = 0.32,     -- degrees per pixel of a horizontal drag over the character
    panMetres = 0.0016,     -- metres per pixel of a vertical drag
    panLimit = 0.45,        -- metres the shot may pan up or down
    driftDegrees = 0.7,     -- slow idle sway of the shot (0 = still)
    driftHeight = 0.006,    -- metres of idle vertical drift
    blendInMs = 800,        -- blend from the game camera into the creator's
    blendOutMs = 550,       -- blend back when the creator closes
    resetTurnOnTravel = true, -- a new rail entry also turns the character back to face the camera
    recentreKey = 'c',      -- key that puts the shot back (turn, zoom, pan); false = none
}

-- Holo look of the rail and the deck: tilted toward the character, hinged on their outer edge (like
-- opx_menu holo and the opx_character selection), with a slow sway on the render thread.
Config.depth = {
    tilt = 13,              -- degrees the side panels turn toward the character (0 = flat)
    perspective = 1250,     -- dp from the eye to the panels; smaller is stronger
    lean = 4,               -- degrees the bottom dock (stepper, buttons) leans back
    sway = 0.6,             -- degrees of idle sway (0 = none)
    swaySeconds = 7,        -- one sway half-cycle
}

-- Left rail. `start` = the entry shown first ('profile' or a category id); `profileShot` = the camera shot of
-- the Profile entry (body type, starting looks, randomize); `labels` = false keeps only the icons (the label
-- of an entry shows on hover and on the active one).
Config.rail = { start = 'profile', profileShot = 'body', labels = true }

-- Right deck: `width` in dp; `strip` = thumbnails in the carousel of the selected option (odd, 3 to 7; the
-- cells shrink to fit the width); `listHeight` = height of the compact option list before it scrolls.
Config.deck = { width = 452, strip = 5, listHeight = 340 }

-- The picture of each starting look on Profile (ui/looks/<file>.png), by preset name of the game's
-- catalogue (lower case). A preset without a picture shows its initial.
Config.looks = { nomad = 'nomad', street = 'street', streetkid = 'street', street_kid = 'street', corpo = 'corpo' }

-- Randomize (Profile: every category; R in a category: that category only). The `sparse` slots keep their
-- default choice (usually none) `sparseChance` of the time, so a roll is not covered in scars and ink.
Config.random = {
    sparse = {
        'body_tattoo_switcher', 'body_scars_switcher', 'scars', 'cyberware_switcher', 'facial_tattoo_switcher',
        'piercings', 'makeupEyes', 'makeupLips_type', 'makeupCheeks', 'makeupPimples', 'beard',
    },
    sparseChance = 0.7,
}

-- Steps back with Backspace (or Ctrl+Z) and the deck's Undo button: changes remembered per body type.
Config.undoDepth = 40

-- Ask twice before what cannot be taken back. `confirmTwice` per mode: Confirm must be pressed again
-- within `windowMs` (in 'creation' the look is final: players have no command to change it later).
-- `cancelTwice`: Cancel / Esc asks again when something was changed (the changes are lost).
Config.safety = {
    confirmTwice = { creation = true, edit = false },
    cancelTwice = true,
    windowMs = 4000,
}

-- The biometric scan around the character: corner brackets that frame the shot.
-- World points are body slots (Open77.character.bonePosition, `bone`) moved by `up`,
-- `forward` and `side` metres in the player's frame; `height` (metres above the feet) is used when the
-- body has no such slot. `frames` picks, per camera shot, the points the brackets span (`top`, `bottom`)
-- and their width as a share of their height (`aspect`). `bounds` keep the brackets off the screen edges,
-- in dp (the deck's width is added on the right). Projection runs each frame only while the creator is open.
-- Chat command printing every body slot and its offsets (to tune Config.scan.points). '' = none.
Config.boneCommand = 'opxbones'

Config.scan = {
    enabled = true,
    refreshMs = 1000,       -- world points are read again this often (a new body moves them)
    -- Metres from a body slot (`bone`), in the character's frame (up / forward / side); `height` above the
    -- feet is the fallback. The game's Head slot sits at jaw level, so the face points are measured up from it.
    points = {
        feet  = { height = 0 },
        crown = { bone = 'head', up = 0.24, height = 1.84 },
        neck  = { bone = 'head', up = -0.08, height = 1.50 },
        hair  = { bone = 'head', up = 0.20, forward = -0.03, height = 1.78 },
        eyes  = { bone = 'head', up = 0.105, forward = 0.09, height = 1.68 },
        face  = { bone = 'head', up = 0.07, forward = 0.11, height = 1.64 },
        mouth = { bone = 'head', up = 0.015, forward = 0.10, height = 1.58 },
        ear   = { bone = 'head', up = 0.08, forward = -0.02, side = 0.075, height = 1.65 },
        head  = { bone = 'head', up = 0.10, height = 1.68 },
        chest = { bone = 'hips', up = 0.36, forward = 0.08, height = 1.36 },
        hand  = { bone = 'right_hand', height = 0.9, side = 0.32 },
    },
    frames = {
        body = { top = 'crown', bottom = 'feet', aspect = 0.42, pad = 16 },
        face = { top = 'crown', bottom = 'neck', aspect = 0.82, pad = 18 },
        eyes = { top = 'crown', bottom = 'mouth', aspect = 1.25, pad = 14 },
        hair = { top = 'crown', bottom = 'neck', aspect = 0.9, pad = 18 },
    },
    bounds = { left = 300, right = 60, top = 70, bottom = 150 },
}

-- Callouts tied to the body, per rail entry: a point of Config.scan.points and the side its label goes
-- ('left' / 'right'; it flips when it would leave the stage). At most 3 per entry; {} = none. Each label
-- is `co_<point>` of the locale, with the point's height above the feet below it.
Config.callouts = {
    profile = { { point = 'head', side = 'left' }, { point = 'chest', side = 'right' } },
    body    = { { point = 'chest', side = 'left' }, { point = 'hand', side = 'right' } },
    face    = { { point = 'face', side = 'left' }, { point = 'ear', side = 'right' } },
    eyes    = { { point = 'eyes', side = 'left' } },
    hair    = { { point = 'hair', side = 'right' } },
    makeup  = { { point = 'eyes', side = 'left' }, { point = 'mouth', side = 'right' } },
    marks   = { { point = 'face', side = 'left' }, { point = 'ear', side = 'right' } },
    clothes = { { point = 'chest', side = 'left' }, { point = 'feet', side = 'right' } },
    headwear = { { point = 'head', side = 'left' }, { point = 'eyes', side = 'right' } },
}

-- Force calm motion for every viewer: camera cuts instead of travels, no drift, sway or self-drawing
-- brackets.
-- NativeUI animations already follow each player's `nui.reducedmotion`; the camera cannot read it.
Config.reducedMotion = false

-- Timings, in milliseconds.
Config.timings = {
    previewDelayMs = 120,   -- a burst of changes is applied once, after this pause
    redressTimeoutMs = 8000, -- give the controls back if a re-dress never reports
    saveTimeoutMs = 15000,  -- client: give the Confirm button back without an answer
    openTimeoutMs = 60000,  -- server: the client did not show the creator in time -> closed 'no_answer'
    saveCooldownMs = 1000,  -- server: minimum delay between two saves of one player
    garbMinMs = 100,        -- server: minimum delay between two clothing previews of one player
    garbAnswerMs = 4000,    -- client: send the next clothing preview anyway when one got no answer
}

-- Game UI sounds (Wwise events, Open77.sfx.play2d). false = silent.
Config.sounds = { hover = 'ui_menu_hover', press = 'ui_menu_onpress' }

-- Largest accepted save payload (one JSON string { body, choices }), in bytes. Capped at 40000 on both
-- sides (a net event over 48 KiB stops the resource); a larger save is refused 'too_large'.
Config.maxPayloadBytes = 60000

-- Options listed per category at most (the document keeps a fixed-length list).
Config.maxRows = 16
