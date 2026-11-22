---@meta
-- LuaLS definitions for opx_creator. Not loaded by the manifest.
-- opx_creator implements the creator contract of docs/ARCHITECTURE.md › Replacing a resource.
-- Callers do not name it: they use exports.opx_core:OpenCreator(...) (opx_core Config.providers.creator).

---@alias CreatorMode 'creation'|'edit'
---@alias CreatorFamily 'male'|'female'
---@alias CreatorCloseReason 'cancelled'|'failed'|'no_answer'|'dropped'|'stopped'|'closed'|'character_changed'|string
--- cancelled  the player cancelled (only offered when canCancel)
--- failed     the client could not show or keep the creator (catalogue, document, character down, in a vehicle)
--- no_answer  the client did not show it within Config.timings.openTimeoutMs
--- dropped    the player disconnected
--- stopped    opx_creator stopped while it was open
--- closed     (or the caller's reason) the Close export, or the staff command `creator <id> close`, ended it
--- character_changed  another resource opened the creator for the player, whose session belonged to a
---            character no longer played (it could never save)
--- unchanged  (opx_creator) Confirm in an 'edit' session that changed nothing: no save, no saved event
---@alias CreatorEntry 'profile'|'body'|'face'|'eyes'|'hair'|'makeup'|'marks'|'clothes'|'headwear'|string a Config.categories id
---@alias CreatorScope 'full'|'clothing'|'barber'|'surgery'|'tattoo'|string a key of Config.scopes
---@alias CreatorOpenError 'invalid_player'|'invalid_options'|'appearance_not_ready'|'busy'|'already_open'|'no_provider'|'uniform_active'
--- already_open: another opener's session is on screen for this character (Close ends it)
--- no_provider / uniform_active: every entry of the session is a clothing one and no skin provider runs /
---   the player wears a uniform (skin provider GetUniform). With other entries, the clothing ones are only left out.
---@alias GarmentSlot 'Head'|'Face'|'InnerChest'|'OuterChest'|'Legs'|'Feet'|'Outfit'

---@class CreatorOptions
---@field mode? CreatorMode default 'edit'
---@field canCancel? boolean default: true in 'edit', false in 'creation'
---@field entries? CreatorEntry[] opx_creator only: the rail entries shown (rail order kept). Without 'profile' the body type cannot change (enforced on save: 'family_locked'). Unknown id -> Open refuses 'invalid_options'.
---@field start? CreatorEntry opx_creator only: the entry shown first (default Config.rail.start, else the first allowed)
---@field title? string opx_creator only: replaces the mode's title (<= 64 bytes, shown in caps)
---@field subtitle? string opx_creator only: replaces the mode's subtitle (<= 160 bytes)
---@field tag? string opx_creator only: the caller's own mark (1 to 64 bytes, no control character), given back in CreatorEventInfo. Invalid -> 'invalid_options'.
---@field opener? string set by opx_core's OpenCreator to the resource that called it; ignored from any other caller (the session then belongs to the calling resource)
---@field scope? CreatorScope opx_creator only: a named set of entries (Config.scopes), default 'full'. `entries` wins over it. Unknown -> 'invalid_options'. A wardrobe = scope 'clothing'.
---@field confirmLabel? string opx_creator only: replaces the Confirm text (e.g. "Pay 150 E$"), cut to 32 bytes. Not a string -> 'invalid_options'.

---@class CreatorEventInfo Last argument of the three opx:creator:* host events (a new table each time).
---@field token string the session's public token (kept when its opener re-opens over it)
---@field mode CreatorMode
---@field tag? string options.tag
---@field opener string the resource the session belongs to (see CreatorOptions.opener)
---@field scope? CreatorScope opx_creator only: the scope of the session
---@field changed? CreatorChanged opx_creator only, on opx:creator:saved: what the save kept

---@class CreatorChanged
---@field body boolean the body (open77_appearance setBodyFamily) was saved
---@field clothing GarmentSlot[] the clothing slots saved through the skin provider ({} = none)

---@class CreatorSessionInfo GetSession answer (a copy).
---@field token string
---@field opener string
---@field tag? string
---@field mode CreatorMode
---@field canCancel boolean
---@field shown boolean
---@field saving boolean
---@field entries? CreatorEntry[]
---@field characterKey string
---@field openedAt integer GetGameTimer() at Open
---@field scope? CreatorScope

---@class CreatorChoices Option name -> choice index, per part (Open77.body.compose input).
---@field head table<string, integer>
---@field body table<string, integer>
---@field arms table<string, integer>

---@class CreatorSession Server-side, per player id.
---@field net integer the client number of the session, echoed in every message (stale messages are ignored); new at every Open
---@field token string the public token (CreatorEventInfo.token)
---@field opener string
---@field tag? string
---@field staff? integer the staff member who opened it for somebody else (notices)
---@field targetName? string the player's name for those notices
---@field mode CreatorMode
---@field canCancel boolean
---@field userId string open77_appearance character(player).userId
---@field characterKey string open77_appearance character(player).characterKey (opx: the citizen id)
---@field shown boolean the client showed the creator
---@field saving boolean a save is being applied (one at a time)
---@field dropped? boolean the player left during a save (the save ends the session)
---@field family? CreatorFamily body type when opened (open77_appearance)
---@field lockFamily boolean entries without 'profile': the save must keep `family`
---@field entries? CreatorEntry[]
---@field start? CreatorEntry
---@field lastSave integer GetGameTimer() of the last save request
---@field openedAt integer
---@field scope? CreatorScope
---@field hasBody boolean an entry edits the body (Profile or a body category): otherwise the body is never touched
---@field hasGarments boolean clothing entries are offered (a skin provider runs, no uniform, clothes read)
---@field garbSlots table<GarmentSlot, true> slots the clothing entries offer (the others keep the worn record)
---@field skin? string the skin provider of the session
---@field worn? table<GarmentSlot, string|false> the character's saved clothes (skin provider GetClothing)
---@field previewed boolean a clothing preview of this session is on (ClearPreview on every close)
---@field bodySaved? boolean the body was saved by an earlier Confirm whose clothes were refused
---@field lastGarb number GetGameTimer() of the last clothing preview request

-- Server exports (the creator contract) ------------------------------------------------------

--- Opens the creator for a player. Re-opening over the caller's own session adopts it (same token, the new
--- mode, cancel, entries, start and title); another opener's session answers 'already_open'. Answers from
--- memory, without yielding.
---@param playerId integer
---@param options? CreatorOptions
---@return boolean ok, CreatorOpenError? reason
function exports.opx_creator:Open(playerId, options) end

---@param playerId integer
---@return boolean
function exports.opx_creator:IsOpen(playerId) end

-- Additions of opx_creator (not part of the creator contract: a replacement need not have them;
-- check `GetProvider('creator') == 'opx_creator'` or pcall before relying on them) ---------------

--- Closes a player's creator without a save; the body from before opening is put back. Raises
--- opx:creator:closed (playerId, reason or 'closed', info). `reason` must match ^[%w_]+$ (else 'closed').
---@param playerId integer
---@param reason? string
---@return boolean ok, ('not_open'|'busy')? err busy = a save is being applied
function exports.opx_creator:Close(playerId, reason) end

---@param playerId integer
---@return CreatorSessionInfo|nil
function exports.opx_creator:GetSession(playerId) end

-- Host events raised (server, AddEventHandler) -----------------------------------------------
-- Exactly one of saved / closed ends every session that Open started.
-- Each carries a last argument `info` (CreatorEventInfo) to tell one opener's session from another's.
-- opx:creator:opened (playerId, info)                        the creator is on screen (again after a re-open)
-- opx:creator:saved  (playerId, characterKey, family, info)  the look was kept: info.changed says what
--     (body through open77_appearance, clothing slots through the skin provider). Charge on it.
--     (setBodyFamily(..., true): the body type is stored at once, the body itself when the client
--     publishes it, which open77_appearance does on its own)
-- opx:creator:closed (playerId, reason, info)                closed without a save (CreatorCloseReason)

-- Save refusals (client status line; reason of opx_creator:saved (token, false, reason)):
-- not_open, busy, too_fast, invalid_family, invalid_look, too_large, family_locked, character_changed, rejected,
-- save_error, invalid_garb, or an open77_appearance / skin provider reason (uniform_active, invalid_outfit_items...).
-- A clothing refusal keeps an 'edit' session open; in 'creation' the body is kept and the clothes stay as they were.

-- Net events (internal) ----------------------------------------------------------------------
-- server -> client: opx_creator:open (token, { mode, canCancel, entries?, start?, title?, subtitle?, confirmLabel?,
--                   hasBody, hasGarments, worn?, skin? }, { male = json?, female = json? }),
--                   opx_creator:saved (token, ok, reason?), opx_creator:garbed (token, ok, reason?, dropped?),
--                   opx_creator:close (token), opx_creator:notice (code, a?, b?): 'refused' (reason),
--                   'opened' / 'closed' / 'not_open' (player name), 'failed' (player name, reason),
--                   'already_open' (player name, opener)
-- client -> server: opx_creator:shown (token), opx_creator:save (token, family, json { body, choices } | false,
--                   garb | false), opx_creator:garb (token, garb) with garb = { [GarmentSlot] = record|false },
--                   opx_creator:closed (token, 'cancelled'|'failed', detail?)

-- Client export: Open77.exports.callSync('opx_creator', 'IsOpen') -> boolean
-- Client event (local, AddEventHandler): opx:creator:visible (visible: boolean, saved: boolean)
--   true when the creator shows, false when it closes (saved = true only when the server confirmed the save).
-- Known limitation (open77_appearance 0.6.0): every preview step is published and stored by it while the
-- hold is on, so a player who disconnects mid-edit keeps the last preview without saved being raised.
-- Do not gate anything valuable on saved alone for BODY edits (barber, surgery): keep them cosmetic, or take
-- the payment before opening and refund it on closed. `entries` only limits the interface for the body; the
-- server enforces the body type, and clothing slots outside the session's entries.
-- Clothing is different: a try-on is a temporary outfit of the skin provider, never stored, and taken off on
-- every close (and by the provider when the player leaves or opx_creator stops). Charging on saved when
-- info.changed.clothing is not empty is safe.

-- Clothing (opx_creator only, optional): the `clothes` / `headwear` entries need the skin provider
-- (opx_core Config.providers.skin) and use its contract only: server GetUniform, GetClothing, SetPreview,
-- ClearPreview, SetClothing; client GetGarments. Without a running provider they are not shown and a
-- session without them behaves as before.

-- Replacing the creator (opx_core Config.providers.creator = '<your resource>') -------------------
-- A replacement implements Open / IsOpen (above, Open must not yield: opx_core uses callSync), ignores
-- option fields it does not know, adopts a re-open over an open session (no closed for the old one),
-- raises opened / exactly one of saved or closed (at least cancelled, failed, dropped), persists only
-- through open77_appearance setBodyFamily(player, family, body, true), and raises the client event
-- open77:appearance:hold (true / false) around a live preview on the player.
-- opx_character uncovers its screen on opened (or after 15 s) and re-opens on any closed during creation.
