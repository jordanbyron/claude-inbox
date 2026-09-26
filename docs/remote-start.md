# Starting sessions from your phone

The inbox can run an HTTP listener that turns a request into the same
`claude --bg` start the `n` form makes. The README has the quick start. This
page has the rest.

## Flags

| Flag | Environment | What it does |
|---|---|---|
| `--listen[=PORT]` | `CLAUDE_INBOX_LISTEN=7433` | listens on `127.0.0.1` only, for an ssh tunnel or scripts on this Mac |
| `--listen-lan[=PORT]` | `CLAUDE_INBOX_LISTEN=lan` or `lan:7433` | listens on every interface, so your LAN and a VPN into it |
| `--listen-allow-modes=default,plan` | `CLAUDE_INBOX_LISTEN_ALLOW_MODES=default,plan` | the permission modes a remote start may use |

The port defaults to 7433, and a flag wins over the environment. Only
`--listen-lan` or `CLAUDE_INBOX_LISTEN=lan` binds every interface. Given both
flags, `--listen-lan` wins and uses its own port, or 7433.

`--fixture` ignores the environment but takes the flags, and keeps a token of
its own. That's how to try the API without starting anything real.

One inbox per user listens. A second one says which process holds the
listener and takes over when that one quits.

## Over your VPN

`N` shows two pairing URLs with the token cut short.
`http://mac-mini.local:7433/#…` works on your Wi-Fi.
`http://192.168.1.20:7433/#…` works over the VPN, since `.local` names don't
cross a tunnel. `c` copies the address form with the token.

The first time, macOS asks whether `ruby` may accept incoming connections.
Allow it. It asks again after a Ruby upgrade, because the binary's path
changes. If the firewall blocks all incoming connections, or stealth mode is
on and `ruby` is denied, the phone gets no answer and nothing says why. `N`
shows the firewall's state.

## Over ssh

Plain `--listen` answers only on `127.0.0.1`. From another machine, run
`ssh -L 7433:127.0.0.1:7433 you@your-mac` and open `http://localhost:7433`.
Any free local port works in place of the first 7433.

Don't use `--listen-lan` for this. macOS lets another program on the Mac bind
`127.0.0.1:7433` next to LAN mode's `0.0.0.0:7433` and take the loopback
traffic, token and all.

## Pairing

The token lives in `~/.config/claude-inbox/listen.json`, readable only by
you, and survives restarts. In the `N` dialog, `r` then `y` replaces it.
Every paired phone then gets 401 until it pairs again.

The dialog also lists the last five remote starts, refusals and rejected
tokens. A repeat bumps a count instead of taking another line.

## The page

The pairing URL opens the `n` form, sized for a phone. Remote Control starts
out on, since you are away from the desk, unless `/config` or the project's
settings turn it off for that directory.

The directory list starts with the ones your sessions ran in lately, then the
projects whose trust dialog you accepted. It remembers your last pick.
"another directory…" takes a typed path.

"default" in a list shows what that directory's settings resolve to, such as
`default (opus)`. If the settings resolve to a permission mode a phone may
not use, it reads `default (acceptEdits: not from a phone)` and can't be
picked. `plan` stands in until you pick a directory that allows it.

Add image takes a photo or picks one from the library. The page scales
anything over 2000 pixels on the long edge down and sends a JPEG, so the
photo's metadata, location included, stays on the phone. An `[Image #1]`
lands at the cursor, as a paste does in the form.

The page keeps what you type until a start goes through. It doesn't keep
photos, so add them again after a reload. If a start gets no answer, Start
resends it under the same key and gets that start's answer, not a second
session. Change anything first and it's a new start. A refusal shows under
the field it's about.

A start that went through shows the session's id. With Remote Control on, it
also links to the session's claude.ai/code page once the session registers
there. The inbox waits three seconds for that. After that the page says
claude.ai/code will list it in a moment.

The page keeps the token and takes it out of the address bar. After you
rotate the token it says "token rejected: press N in the inbox and pair
again" and asks for the new pairing URL. The inbox serves the page, so with
the inbox closed or the Mac asleep the Home Screen icon has nothing to open.

## Permission modes

A remote start may use `default`, `auto` and `plan`. The inbox works out
what `default` means for the directory first, so a project whose settings
default to `bypassPermissions` gets a 403, not a session.
`--listen-allow-modes` replaces the list, for example
`--listen-allow-modes=default,plan,acceptEdits`. The inbox doesn't read
managed settings, so they play no part in that check.

## In the inbox

A remote start never moves the cursor, attaches, or closes what you have
open. The header says `started 31472308 from 192.168.1.30`, and the row turns
up on the next poll.

The header shows `◉ :7433` while the inbox listens and `◉ lan:7433` in LAN
mode, where the footer also shows `N pair`. A red `◉ !` means the inbox was
asked to listen and can't, because another inbox has the listener or
something else holds the port. It retries every few seconds and turns blue
once it has the port. An inbox that quits while a client still has a
connection open can leave the port held for half a minute. Anything else,
such as a `~/.config/claude-inbox` it can't write to, stays red, and `N` says
what went wrong.

## The API

`GET /api/options` lists the models, efforts, permission modes and
directories a start can use. Each directory has a short `label` and the
defaults its settings give. `POST /api/sessions` starts a session. The token
is the part of the pairing URL after the `#`, or:

```sh
TOKEN=$(ruby -rjson -e 'puts JSON.parse(File.read(File.expand_path("~/.config/claude-inbox/listen.json")))["token"]')
curl -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"prompt":"fix the flaky spec","cwd":"claude-inbox","remote":true}' \
  http://192.168.1.20:7433/api/sessions
```

The fields match the `n` form. `cwd` takes a path or a directory's label.

- `prompt`, `name`, `cwd`, `model`, `effort`, `permission_mode`, `worktree`
- `remote`, which follows "Enable Remote Control for all sessions" in
  `/config` when left out, as the form does
- `images`, up to eight `{"data": "<base64>"}` PNG, JPEG, GIF or WebP images
  the prompt can refer to as `[Image #1]`

The listener refuses an unknown key, so a misspelt setting can't quietly fall
back to its default.

Success is `201 {"id", "name", "cwd", "url"}`. `url` is the session's
claude.ai/code page, or null if the session hasn't registered within three
seconds. Without `remote` the inbox doesn't wait, since such a session seldom
registers at all.

A refusal is `{"error", "field"}` with the message the form would show. A CLI
refusal such as "Workspace not trusted" comes back as a 500.

Send an `Idempotency-Key` header and a retry gets the first answer instead of
starting a second session. Reusing a key with a different request gets a 422.

## An iOS Shortcut

A Shortcut can send the same request from the share sheet, with the photos or
text you shared.

1. Receive Images and Text from the Share Sheet.
2. Get Images from the Shortcut Input. Repeat with Each: Resize Image to 2000
   on the longest edge, Convert Image to JPEG, Base64 Encode, then a
   Dictionary with `data` set to the encoded text, and Add to Variable
   `images`.
3. Ask for Input for the prompt, with the shared text as its default.
4. Get Contents of URL `http://192.168.1.20:7433/api/sessions`, method POST,
   with the headers `Authorization: Bearer <token>` and `Idempotency-Key`,
   and a JSON body of `prompt`, `cwd`, `remote` set to true, and `images` as
   the variable.
5. Show the answer, or Open URLs on its `url`.

Make the key a Random Number between 1 and 1000000000. The Current Date as
text only goes to the minute, and a second start that reuses a key gets the
first one's answer and starts nothing.

Give `cwd` as a path such as `~/code/claude-inbox`, not a label. A label
grows a parent directory when another directory of the same name turns up,
and the saved Shortcut would start getting a 422.

Put the token in a Text action at the top. If you share the Shortcut, make
that action an Import Question so the token stays out of what you share.
