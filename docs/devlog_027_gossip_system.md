# Devlog 027 — Gossip System (Memory Propagation)

## What Changed
NPCs now share interesting memories during NPC-to-NPC conversations, creating a gossip network where information propagates through town. Maria witnesses something → tells Rose at the Tavern → Rose tells Thomas at the General Store. Information degrades with each hop, and trust determines willingness to share.

## Gossip Selection (`_pick_gossip_for()`)
When two NPCs finish a conversation, each has a 40% chance of sharing gossip. Selection criteria:
- **Trust threshold:** Minimum 15 trust required (don't gossip with strangers/enemies)
- **Recency:** Memory must be < 48 hours old
- **Importance:** Must be ≥ 3.0 (skip mundane observations)
- **Third parties only:** About someone OTHER than the conversation partner or self
- **No re-sharing to source:** Won't tell Maria something Maria originally told you
- **Not already witnessed:** Skip if conversation partner was a participant
- **Juiciest first:** Sorted by importance × recency — picks the best candidate

## Gossip Propagation (`_share_gossip_with()`)
When gossip is shared, the receiver gets a new memory:
- **Type:** `"gossip"` (new memory type)
- **Format:** First-hand: `"Maria told me: [original description]"` / Second-hand+: `"Maria mentioned that they heard: [description]"`
- **Importance degrades:** Original importance - (hop_count × 1.0), minimum 2.0
- **Max 3 hops:** Prevents infinite telephone game
- **Tracking fields:** `gossip_source`, `gossip_hops`, `original_description`

The sharer also gets a memory: `"Told Rose about [description]"` (type: `"gossip_shared"`, importance 2.0)

## Relationship Effects
- **Sharing gossip:** +1 mutual trust (intimacy of shared secrets)
- **Negative gossip about X:** Receiver's trust/affection/respect toward X decreases (-2/-1/-1)
- **Positive gossip about X:** Receiver's opinion of X slightly increases (+1/+1/0)
- Trust threshold means NPCs naturally form gossip circles among friends

## Context Enrichment
- **NPC-to-NPC chat:** Recent gossip included as "Things you've heard recently: ..."
- **Player dialogue:** General gossip under "Things you've heard from others" + specific player gossip under "You've heard things about this person from others"
- **Topic selection:** Gossip memories generate conversation topics ("what they heard about {person}")

## Example Flow
```
1. Elena sees Player near the Blacksmith at midnight (observation, importance 5.0)
2. Elena chats with Rose → [Gossip] Elena told Rose: "Saw Player near the Blacksmith" (hop 1, importance 4.0)
3. Rose chats with Thomas → [Gossip] Rose told Thomas: "Rose mentioned: Saw Player..." (hop 2, importance 3.0)
4. Thomas chats with Maria → [Gossip] Thomas told Maria: "..." (hop 3, importance 2.0)
5. Maria chats with Finn → gossip does NOT spread (max 3 hops reached)
6. Player talks to Rose → she says "I heard you were snooping around the Blacksmith..."
```

## Memory Types (Updated)
| Type | Description | Example |
|------|-------------|---------|
| observation | Firsthand sighting | "Saw Maria kneading dough near the Bakery" |
| dialogue | Conversation record | "I said to Rose: ..." |
| reflection | Synthesized insight | "I think Maria works too hard" |
| environment | Object state notice | "The oven at the Bakery was baking" |
| gossip | Heard from others | "Maria told me: Saw Player near the Blacksmith" |
| gossip_shared | Record of telling | "Told Rose about Saw Player near the Blacksmith" |

## Save System
New `gossip_heard.json` per NPC alongside existing saves:
```json
[{"time": 1440, "from": "Elena", "about": "Player", "description": "Elena told me: ...", "hops": 1}]
```

## Performance
- Gossip check runs only after completed conversations (not per-frame)
- Iterates NPC's memory array once per gossip attempt — bounded by 200-memory cap
- Max 2 gossip events per conversation (one per NPC)
- 40% chance gate prevents most conversations from triggering gossip at all

## Files Changed
| File | Action |
|------|--------|
| `scripts/npc/npc_controller.gd` | MODIFY — `_pick_gossip_for()`, `_share_gossip_with()`, gossip wired into both conversation paths, gossip context in dialogue + NPC chat, gossip-aware topic selection |
| `scripts/world/town.gd` | MODIFY — Gossip log saved to `gossip_heard.json` per NPC |
