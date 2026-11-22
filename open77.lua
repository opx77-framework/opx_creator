resource "opx_creator"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- The OPX in-world character creator (NativeUI) on the official building blocks: the game's catalogue
-- and live preview through Open77.body, the look applied, replicated and persisted by open77_appearance.
-- Implements the creator contract of docs/ARCHITECTURE.md (exports Open / IsOpen, opx:creator:* events).
dependency "open77_appearance >=0.5.0"

permissions {
    "network.events",      -- client <-> server: open, shown, save, closed
    "database.access",     -- server: the creator choices (opx_creator_looks)
    "player.body.switch",  -- client: Open77.body catalog / compose / decompose / active / state / capture / switch
    "camera.script",       -- client: the creator's camera shots
    "player.freeze",       -- client: Open77.character.setFrozen while the creator is open
    "world.transform",     -- client: Open77.character.offsetToWorld / bonePosition (camera frame, scan points)
    "ui.vanilla.hud",      -- client: Open77.hud.setCinematic (clean view), Open77.hud.notify (staff notices)
    "world.effects",       -- client: Open77.sfx.play2d (UI sounds)
    "session.locale",      -- client: Open77.session.locale (Config.locale = 'auto')
}

shared_script "config.lua"

server_scripts {
    "server/state.lua",
    "server/main.lua",
}

client_script "client/main.lua"

files {
    "client/modules/*.lua",
    "locales/*.json",
    "ui/creator.rml",
    "ui/creator.rcss",
    "ui/thumbs/*.png",
    "ui/looks/*.png",
}
