from PIL import Image, ImageDraw


# Draw small then enlarge with nearest-neighbour for crisp 16-bit pixels.
W, H, SCALE = 256, 176, 3
img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

INK = "#211827"; DEEP = "#352035"; WALNUT = "#5a3035"; WOOD = "#824538"
CEDAR = "#a9583d"; ORANGE = "#d87943"; LIGHT = "#ed9b56"; GOLD = "#e9ad52"
CREAM = "#ffe08a"; GLASS = "#30516a"; GLASS_LIT = "#72a8a0"; SHADOW = (25, 15, 28, 96)

def rect(box, color): d.rectangle(box, fill=color)
def px(x, y, color, w=2, h=2): rect((x, y, x + w - 1, y + h - 1), color)
def outlined(box, fill, border=2):
    rect(box, INK); x1, y1, x2, y2 = box; rect((x1 + border, y1 + border, x2 - border, y2 - border), fill)

# Contact shadow only: the remaining backdrop is genuine transparency.
d.ellipse((23, 158, 234, 171), fill=SHADOW); rect((34, 162, 222, 167), SHADOW)

# Deep roof, tall false front, and planked facade.
d.polygon([(29, 72), (48, 47), (208, 47), (227, 72)], fill=INK)
d.polygon([(38, 70), (53, 52), (203, 52), (218, 70)], fill=DEEP)
rect((46, 58, 210, 73), "#4a2733")
outlined((42, 66, 214, 153), WOOD, 3); rect((47, 72, 209, 148), CEDAR); rect((47, 121, 209, 148), WOOD)
d.polygon([(57, 65), (57, 34), (68, 34), (68, 27), (188, 27), (188, 34), (199, 34), (199, 65)], fill=INK)
d.polygon([(61, 64), (61, 38), (72, 38), (72, 31), (184, 31), (184, 38), (195, 38), (195, 64)], fill=WOOD)
rect((67, 42, 189, 64), CEDAR); rect((71, 45, 185, 61), "#713a38")

# Carved cornices.
rect((53, 64, 203, 69), INK); rect((57, 64, 199, 66), LIGHT)
rect((46, 73, 210, 78), INK); rect((49, 74, 207, 76), ORANGE)
rect((46, 117, 210, 122), INK); rect((49, 118, 207, 120), LIGHT)

# Gold saloon plaque.
outlined((77, 39, 179, 60), GOLD); rect((81, 43, 175, 56), "#6d3938"); rect((84, 45, 172, 47), "#914737")
for x in (80, 174): px(x, 42, CREAM, 3, 3); px(x, 54, CREAM, 3, 3)
glyphs = {"S": ("111", "100", "111", "001", "111"), "A": ("010", "101", "111", "101", "101"), "L": ("100", "100", "100", "100", "111"), "O": ("111", "101", "101", "101", "111"), "N": ("101", "111", "111", "111", "101")}
for i, char in enumerate("SALOON"):
    for yy, row in enumerate(glyphs[char]):
        for xx, bit in enumerate(row):
            if bit == "1": px(89 + i * 12 + xx * 2, 48 + yy * 2, CREAM)

# Planks with irregular warm grain.
for x in range(50, 209, 13):
    rect((x, 78, x + 2, 116), WALNUT); rect((x + 3, 79, x + 4, 115), ORANGE)
for x in (65, 104, 151, 190): rect((x, 79, x + 1, 114), LIGHT)

# Glass windows.
for x in (57, 164):
    outlined((x, 84, x + 28, 110), DEEP); rect((x + 3, 87, x + 25, 107), GLASS); rect((x + 4, 88, x + 24, 92), GLASS_LIT)
    rect((x + 13, 87, x + 15, 107), INK); rect((x + 3, 98, x + 25, 100), INK)
    rect((x + 5, 102, x + 10, 105), "#42647b"); rect((x + 18, 102, x + 23, 105), "#42647b")

# Layered swinging doors.
outlined((105, 82, 151, 148), DEEP, 3); rect((109, 87, 127, 145), "#773c36"); rect((129, 87, 147, 145), "#653139")
for y in (90, 108, 132):
    rect((111, y, 125, y + 4), CEDAR if y != 108 else WALNUT); rect((131, y, 145, y + 4), "#93483a" if y != 108 else WALNUT)
px(124, 117, GOLD, 3, 3); px(130, 117, GOLD, 3, 3)

# Porch awning, posts, lanterns.
d.polygon([(34, 119), (222, 119), (232, 128), (24, 128)], fill=INK); d.polygon([(39, 121), (217, 121), (224, 126), (32, 126)], fill="#4b2933")
rect((34, 126, 222, 130), INK); rect((39, 126, 217, 127), LIGHT)
for x in (42, 211):
    rect((x, 127, x + 7, 158), INK); rect((x + 2, 129, x + 5, 158), CEDAR); rect((x + 3, 131, x + 4, 156), LIGHT)
for x in (51, 197):
    rect((x + 4, 76, x + 5, 82), INK); rect((x + 1, 81, x + 8, 92), INK); rect((x + 2, 83, x + 7, 90), GOLD); rect((x + 3, 84, x + 6, 89), CREAM); rect((x + 3, 92, x + 6, 94), INK)

# Stepped boardwalk.
rect((33, 151, 223, 156), INK); rect((38, 151, 218, 153), ORANGE)
rect((48, 156, 208, 160), INK); rect((55, 156, 201, 158), LIGHT)
rect((64, 160, 192, 164), INK); rect((70, 160, 186, 162), CEDAR)

# Barrels and hitching rail.
for x, y in ((24, 138), (220, 141)):
    outlined((x, y, x + 17, y + 19), WALNUT); rect((x + 2, y + 5, x + 15, y + 7), GOLD); rect((x + 2, y + 13, x + 15, y + 15), GOLD); rect((x + 5, y + 2, x + 12, y + 3), CEDAR); rect((x + 5, y + 17, x + 12, y + 18), CEDAR)
rect((14, 145, 27, 148), INK); rect((14, 145, 27, 146), CEDAR); rect((16, 147, 18, 160), INK); rect((24, 147, 26, 160), INK)
for x, y in [(54, 80), (92, 80), (157, 81), (201, 81), (97, 115), (156, 115), (74, 143), (181, 143)]: px(x, y, LIGHT, 2, 1)
for x, y in [(75, 104), (89, 88), (183, 108), (202, 99), (59, 134)]: px(x, y, DEEP)

img.resize((W * SCALE, H * SCALE), Image.Resampling.NEAREST).save("assets/saloon_16bit.png")
