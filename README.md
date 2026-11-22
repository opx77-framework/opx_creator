# opx_creator

In-world character creator: a holo interface around the live character to pick body type, face, hair, makeup, marks and clothes. Replaces the official `open77_creator`. A wardrobe, a clothing shop or a barber is this creator opened in a scope (only some entries).

## Install
- Needs: `open77_appearance >= 0.5.0`. Load after it and `opx_core`, before `opx_character`.
- Clothing entries need a skin provider (`opx_core` `Config.providers.skin`, `opx_skin` by default): load it before `opx_creator`. Without it the clothing entries are simply not shown.
- Creates its `opx_creator_looks` table at start (without a database, choices last for the session only).
- Do not load the official `open77_creator`. Set the convar `"open77_appearance_creation": "runtime"`.
- Provider of the creator slot (`opx_core` `Config.providers.creator`): a replacement implements the exports and events in `types.lua`.
- Staff command: grant the ACL right `command.creator`.

## In game
- Q / E: turn the character. Mouse wheel: zoom. Drag: turn and pan.
- Up / Down: pick an option. Left / Right: change its value (Shift: 10 garments at a time). R: randomize. Backspace: undo.
- Tab or 1-9: next entry. Enter: confirm. Esc: cancel (when allowed).
- Clothes are tried on live (other players see the fitting); nothing is kept before Confirm. A garment other than a full outfit takes the full outfit off.
- `/creator [playerId] [scope]` (staff, `command.creator`): open in edit mode, e.g. `/creator 12 clothing`. `/creator [playerId] close`: close it.

## Config
`config.lua`: `Config.locale`, `Config.command`, `Config.categories`, `Config.scopes` (full, clothing, barber, surgery, tattoo; add your own), `Config.clothing` (starter clothes of a new character, Shift step), `Config.reducedMotion`. Everything else is commented in the file.

## For developers
- Open it through `exports.opx_core:OpenCreator(playerId, options)` so the creator stays replaceable.
- `Open(playerId, options?)` → `true, token` or `false, reason`. `IsOpen(playerId)` → boolean.
- Options: `mode`, `canCancel`, `scope` (a `Config.scopes` key), `entries` (wins over `scope`), `start`, `title`, `subtitle`, `tag`, `confirmLabel` (Confirm text, e.g. "Pay 150 E$").
- `Close(playerId, reason?)` and `GetSession(playerId)`: opx_creator only, not in the contract.
- Events: `opx:creator:opened (playerId, info)`, `opx:creator:saved (playerId, characterKey, family, info)`, `opx:creator:closed (playerId, reason, info)`. Exactly one of saved / closed per session. `info.scope`; on saved, `info.changed = { body = boolean, clothing = { 'Legs', ... } }`.
- An `edit` session confirmed without any change closes with reason `unchanged` (no saved event).
- Clothing shop or wardrobe: `OpenCreator(src, { scope = 'clothing', tag = 'shop:x', confirmLabel = 'Pay 150 E$' })`, charge on `saved` when `info.opener` is you and `info.changed.clothing` is not empty. A try-on is never stored, so this is safe.
- Barber / surgery (body edits): same pattern, with one known limitation: a player who disconnects mid-edit keeps his last body preview without `saved` (cosmetic, free). To close that gap, charge before opening and refund on `closed`.
- Full contract: `types.lua`.
