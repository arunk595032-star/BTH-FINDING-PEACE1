extends RefCounted
## Shared, deterministic description of the BTH world.
##
## Everything that defines the landscape lives here: size, seed, region
## weights, the river/road splines and the settlement anchors.  Both the
## runtime world builder and the offline map/data tools read this file so the
## map preview always matches the playable world.

const SEED := 20260419

# --- Terrain ---------------------------------------------------------------
const WORLD_SIZE := 2048.0          # metres, square
const WORLD_HALF := 1024.0
const CHUNK_SIZE := 128.0           # metres per streaming terrain chunk
const CHUNK_SEGMENTS := 48          # quads per chunk side  (~2.67 m)
const STREAM_RADIUS := 448.0        # chunks loaded within this distance
const UNLOAD_RADIUS := 576.0

# --- Region anchors (world metres, XZ plane, -Z is north) ------------------
const VILLAGE_CENTER := Vector2(-168.0, 236.0)
const CASTLE_CENTER := Vector2(438.0, -132.0)
const HAMLET_CENTER := Vector2(322.0, 742.0)
const WATCHTOWER_SITE := Vector2(-486.0, 610.0)
const RUINS_SITE := Vector2(536.0, 292.0)
const CAMP_SITE := Vector2(-616.0, -196.0)
const CAVE_SITE := Vector2(-268.0, -706.0)
const WATERFALL_SITE := Vector2(352.0, -372.0)
const PLAYER_SPAWN := Vector3(-196.0, 0.0, 300.0)

# --- Water -----------------------------------------------------------------
# Each river is authored as a polyline from source (high) to mouth (low).
# `level` is the water surface height at that point, `width` the water width.
const RIVER_POINTS := [
	{"p": Vector2(-62.0, -948.0), "level": 148.0, "width": 9.0},
	{"p": Vector2(-96.0, -840.0), "level": 120.0, "width": 12.0},
	{"p": Vector2(-58.0, -742.0), "level": 96.0, "width": 14.0},
	{"p": Vector2(-30.0, -640.0), "level": 74.0, "width": 17.0},
	{"p": Vector2(6.0, -548.0), "level": 58.0, "width": 19.0},
	{"p": Vector2(-22.0, -452.0), "level": 44.0, "width": 22.0},
	{"p": Vector2(38.0, -344.0), "level": 32.0, "width": 25.0},
	{"p": Vector2(-58.0, -226.0), "level": 24.0, "width": 28.0},
	{"p": Vector2(-98.0, -96.0), "level": 18.0, "width": 30.0},
	{"p": Vector2(-46.0, 34.0), "level": 14.0, "width": 32.0},
	{"p": Vector2(-104.0, 172.0), "level": 11.0, "width": 34.0},
	{"p": Vector2(-56.0, 306.0), "level": 9.0, "width": 36.0},
	{"p": Vector2(16.0, 448.0), "level": 7.5, "width": 38.0},
	{"p": Vector2(-14.0, 606.0), "level": 6.5, "width": 40.0},
	{"p": Vector2(-70.0, 762.0), "level": 6.0, "width": 46.0},
	{"p": Vector2(-6.0, 918.0), "level": 5.5, "width": 58.0},
	{"p": Vector2(18.0, 1010.0), "level": 5.2, "width": 74.0},
]

# Eastern highland stream: feeds the main river through a waterfall.
const STREAM_POINTS := [
	{"p": Vector2(742.0, -430.0), "level": 112.0, "width": 5.0},
	{"p": Vector2(606.0, -404.0), "level": 92.0, "width": 6.0},
	{"p": Vector2(486.0, -392.0), "level": 74.0, "width": 7.0},
	{"p": Vector2(392.0, -378.0), "level": 58.0, "width": 8.0},
	{"p": Vector2(352.0, -372.0), "level": 26.0, "width": 9.0},
	{"p": Vector2(302.0, -330.0), "level": 23.5, "width": 10.0},
	{"p": Vector2(232.0, -262.0), "level": 21.0, "width": 12.0},
	{"p": Vector2(170.0, -200.0), "level": 19.0, "width": 13.0},
	{"p": Vector2(96.0, -150.0), "level": 17.0, "width": 14.0},
]

# Western forest creek.
const CREEK_POINTS := [
	{"p": Vector2(-742.0, 372.0), "level": 46.0, "width": 3.0},
	{"p": Vector2(-612.0, 344.0), "level": 36.0, "width": 4.0},
	{"p": Vector2(-486.0, 330.0), "level": 27.0, "width": 5.0},
	{"p": Vector2(-352.0, 318.0), "level": 19.0, "width": 6.0},
	{"p": Vector2(-232.0, 344.0), "level": 13.0, "width": 8.0},
	{"p": Vector2(-140.0, 380.0), "level": 9.5, "width": 9.0},
]

# --- Roads -----------------------------------------------------------------
# `width` is the full carriageway width in metres, `surface` selects the
# terrain blend (0 = packed dirt road, 1 = narrow trail).
const ROADS := [
	{
		"name": "Kingsroad",
		"width": 6.5,
		"surface": 0.0,
		"points": [
			Vector2(-196.0, 152.0), Vector2(-186.0, 96.0), Vector2(-120.0, 30.0),
			Vector2(-46.0, -34.0), Vector2(40.0, -62.0), Vector2(150.0, -76.0),
			Vector2(268.0, -104.0), Vector2(376.0, -128.0), Vector2(438.0, -132.0),
		],
	},
	{
		"name": "South road",
		"width": 6.0,
		"surface": 0.0,
		"points": [
			Vector2(-196.0, 268.0), Vector2(-196.0, 360.0), Vector2(-150.0, 452.0),
			Vector2(-40.0, 540.0), Vector2(96.0, 604.0), Vector2(210.0, 668.0),
			Vector2(322.0, 742.0),
		],
	},
	{
		"name": "Mountain pass road",
		"width": 5.0,
		"surface": 0.0,
		"points": [
			Vector2(-120.0, 30.0), Vector2(-210.0, -60.0), Vector2(-268.0, -170.0),
			Vector2(-300.0, -290.0), Vector2(-320.0, -420.0), Vector2(-286.0, -540.0),
			Vector2(-268.0, -640.0), Vector2(-268.0, -706.0),
		],
	},
	{
		"name": "Forest trail",
		"width": 2.6,
		"surface": 1.0,
		"points": [
			Vector2(-196.0, 236.0), Vector2(-280.0, 236.0), Vector2(-380.0, 268.0),
			Vector2(-486.0, 330.0), Vector2(-520.0, 440.0), Vector2(-486.0, 560.0),
			Vector2(-486.0, 610.0),
		],
	},
	{
		"name": "Highland trail",
		"width": 2.4,
		"surface": 1.0,
		"points": [
			Vector2(438.0, -132.0), Vector2(500.0, -40.0), Vector2(536.0, 92.0),
			Vector2(536.0, 200.0), Vector2(536.0, 292.0),
		],
	},
	{
		"name": "Village lane",
		"width": 3.6,
		"surface": 0.0,
		"points": [
			Vector2(-196.0, 236.0), Vector2(-262.0, 214.0), Vector2(-322.0, 176.0),
			Vector2(-352.0, 96.0),
		],
	},
]

# --- Regions (HUD + documentation) ----------------------------------------
const REGIONS := [
	{"name": "The Northern Peaks", "center": Vector2(-40.0, -760.0), "radius": 430.0},
	{"name": "Eastern Highlands", "center": Vector2(730.0, -120.0), "radius": 430.0},
	{"name": "Whisperwood", "center": Vector2(-560.0, 120.0), "radius": 380.0},
	{"name": "Ashenfall Ruins", "center": Vector2(536.0, 292.0), "radius": 220.0},
	{"name": "Tarnwatch Keep", "center": Vector2(438.0, -132.0), "radius": 210.0},
	{"name": "Golden Valley", "center": Vector2(-40.0, 120.0), "radius": 330.0},
	{"name": "Thornbury Village", "center": Vector2(-168.0, 236.0), "radius": 190.0},
	{"name": "The Southern Fields", "center": Vector2(120.0, 760.0), "radius": 430.0},
	{"name": "Silverwater Lake", "center": Vector2(0.0, 980.0), "radius": 260.0},
]
