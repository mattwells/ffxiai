# FFXI-AI

A Windower 4 addon for Final Fantasy XI that lets your AI assistant see your game. Ask things like:

- "What's in my Mog Safe? Do I have any Hi-Potions anywhere?"
- "Who in my party is low on MP?"
- "What am I wearing, and what augments are on it?"
- "How long until Convert is back up?"
- "What did my linkshell just say?"

It is **read-only**: it reads what your game client already knows, and it never sends anything to the game server unless you turn on [requests](#requests-to-the-game-server).

Technically it's an MCP server (Model Context Protocol, the standard way AI apps connect to tools), so it works with Claude, ChatGPT and other MCP apps.

## Install

1. Put this folder in `Windower/addons/` so the files are at `Windower/addons/ffxiai/ffxiai.lua`.
2. In game: `//lua load ffxiai`. To load it every time, add `lua load ffxiai` to `Windower/scripts/init.txt`.

If you play several characters at once, load it on each of them. They all work together, and the AI can see every one.

## Connect your AI app

This only works with an AI app installed on the PC that's running the game. The web versions, such as claude.ai or chatgpt.com in a browser, and the phone apps can't reach it.

### Claude desktop app

1. Download **[FFXI-AI.mcpb](https://github.com/mattwells/ffxiai/raw/master/FFXI-AI.mcpb)**. It's also in the addon folder if you downloaded the whole addon.
2. In the Claude app, open **Settings → Desktop app**, scroll to the bottom, and click **Manage** next to **Extensions**. Drag the file onto that page. (Or click **Advanced settings → Install Extension…** there and pick the file.) Click **Install** when Claude asks.
3. Start the game with FFXI-AI loaded, then ask Claude about your characters.

You don't need to install anything else, and nothing needs typing. If Claude was open before the game, it picks up the tools once the game is running. If it doesn't, restart Claude.

### ChatGPT desktop app

Open **Settings → Plugins → Add → Add MCP server**, choose **Streamable HTTP**, and enter:

- **Name:** `FFXI-AI`
- **URL:** `http://127.0.0.1:19750/mcp`

### Other apps

Add an MCP server with the address `http://127.0.0.1:19750/mcp`. Apps call this "HTTP" or "Streamable HTTP". The address only works on the PC running the game.

## What the AI can see

| Tool | What it reads |
|---|---|
| `list_characters` | Every character running the addon: job, zone, status, HP/MP, TP |
| `get_player` | Jobs and levels, HP/MP/TP, status, buffs and debuffs with time left, every job's level |
| `get_target` | Target, sub-target, battle target and pet: HP %, distance, who has claim |
| `get_party` | Party and alliance: HP/MP, TP, zone, distance, leader |
| `get_inventory` | A bag's items, counts and augments, plus gil. Can search every bag and storage slip, optionally by whole word |
| `get_equipment` | What's in each slot, which bag it's from, augments, path and rank |
| `get_recasts` | Abilities and spells on cooldown |
| `get_location` | Zone, position, weather, Vana'diel time and day, moon, server |
| `get_merits` | Merit points and limit points, merits spent, and per job: capacity points, job points and categories |
| `get_currencies` | Both Currencies pages (Sparks, Bayld, seals, beads, Gallimaufry and so on), with how old they are |
| `get_skills` | Combat and magic skills, and crafting levels and ranks, with whether each is capped |
| `get_stats` | STR, DEX and the rest (base and from gear), attack, defense, resistances, EXP, Master Level, title, nation rank, Unity |
| `get_job_setup` | Blue magic set; automaton head, frame, attachments, skills and stats; or Monstrosity species |
| `get_treasure_pool` | What's in the treasure pool, how long is left and the highest lot |
| `get_nearby` | Monsters, players or NPCs nearby, nearest first, with HP, distance and who has claim |
| `get_missions` | Mission progress in every storyline, from the nations to The Voracious Resurgence: current mission, finished or not, and every mission's status. The game sends this when you zone |
| `get_quests` | Quest progress in every area (the nations, Jeuno, Other Areas, Outlands, Aht Urhgan, Crystal War, Abyssea, Adoulin, Coalition): counts, what's in progress, and each quest's status. Searchable by name. Also sent when you zone |
| `lookup` | Game data from Windower's resources: item stats, spells, abilities, weapon skills, buffs, key items, job traits, zones. Can search item descriptions and limit results to what a character has |
| `get_chat` | Recent chat, only if you [turn it on](#chat) |

With several characters logged in, the AI picks one by name or asks all of them at once.

## Chat

Chat reading is off by default. Settings are per character:

- `//ffxiai chat on` lets the AI read chat received from then on (the last 200 lines).
- `//ffxiai tells on` also includes tells, which stay out otherwise.

Turning chat off clears what was kept.

## Requests to the game server

The game server doesn't send some information until you open a menu for it. Currencies are the main example: your Sparks, seals, Bayld and so on only reach your game when you open **Menu → Profile → Currencies** (or **Currencies 2**). Each page arrives separately.

With requests off (the default), FFXI-AI never sends anything to the game server. When you ask about currencies, it shows what the game sent the last time you opened that menu, and how long ago that was. If you haven't opened the menu since logging in, there's nothing to show yet.

- `//ffxiai requests on` lets FFXI-AI get current values itself. It sends the same request the game sends when you open the menu. It only asks for information and never does anything in game.
- `//ffxiai requests off` turns it back off.

The setting is saved per character, like chat.

## Checking on it

You shouldn't need to type anything. `//ffxiai` shows whether this character is hosting or connected, which characters are connected and how many requests the AI has made. `//ffxiai log on` prints connection events in the chat log.

If another program already uses port 19750, the addon says so once. Change `port` in `data/settings.xml` (in the global section), set the same port on every character and in your AI app, then reload.

## Privacy

The server only listens on `127.0.0.1`, so nothing else on your network can reach it. It rejects requests from web pages and from any address that isn't local.

## Credits

Mission names, quest titles and how to read the game's quest and mission log come from [Chronicle](https://github.com/jintawk/ffxi-chronicle) by Jintawk, a quest and mission tracker for Windower. `missions.lua` and `quests.lua` are copies of Chronicle's mission and quest name tables and keep its copyright notice.
