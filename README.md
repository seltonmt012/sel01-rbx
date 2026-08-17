# sel01-rbx

One loader, one panel design, one script per game.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/seltonmt012/sel01-rbx/main/loader.lua"))()
```

Paste that once. The loader reads `index.json`, works out which game you are in,
and runs the matching script from `games/`. It re-arms itself on teleport, so a
lobby that sends you into a separate map place keeps the automation.

## Layout

| path | what it is |
| --- | --- |
| `loader.lua` | the only thing you ever execute |
| `index.json` | the registry: place ids, detection snippets, file names |
| `lib/ui-template.lua` | the panel every script builds its UI from |
| `games/*.lua` | one automation script per game |
| `vendor/` | third-party files, not loaded by anything |

## How a game is matched

1. **PlaceId** against `places` in the registry.
2. If that misses, the entry's `detect` snippet runs — a line of Lua returning a
   boolean. Place ids change between a lobby, a map and a private server; the
   modules and remotes a game exposes do not, so detection is what keeps the
   loader working on places nobody has written down yet.
3. Still nothing: a picker panel lists every script and lets you force one.
   `_G.__SEL.load("lootevo")` does the same from the console.

## Runtime handle

`_G.__SEL` is left behind for the console:

| field | |
| --- | --- |
| `load(alias)` | run a script by name, ignoring detection |
| `list()` | every registered game |
| `reload()` | re-download and re-run the loader |
| `picker()` | open the picker panel |
| `ui` | the loaded UI template, shared by every script |
| `game` | the entry that was matched |
| `index` | the decoded registry |

## Adding a game

Drop the script into `games/`, add an entry to `index.json`:

```json
{
  "alias": "mygame",
  "name": "My Game",
  "file": "games/mygame.lua",
  "places": [123456789],
  "status": "ok",
  "detect": "return game.Workspace:FindFirstChild('SomethingOnlyThisGameHas') ~= nil"
}
```

Scripts get the shared panel through `_G.__SEL.ui` and fall back to
`readfile("ui-template.lua")` when they are run by hand outside the hub.

Caching: everything downloaded is written into the executor workspace under
`sel01/`, and a failed request falls back to that copy rather than to nothing.
