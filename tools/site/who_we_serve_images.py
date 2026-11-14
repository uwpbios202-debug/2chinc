#!/usr/bin/env python3
"""
Copy Who We Serve posters from incoming/images (named by their tagline, as
generated) into site/who-we-serve/images/<slug>.jpg, resized for the web.

The generated file names don't say which group a poster is for, so each one
is matched here by hand after looking at it. Re-run after adding new posters;
files not listed are reported so they can be matched.

Usage:  python tools/site/who_we_serve_images.py
"""
import os
import re

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "incoming", "images")
DST = os.path.join(ROOT, "site", "who-we-serve", "images")

# incoming file name -> slug on the site (slugs: see P in site/who-we-serve/index.html).
# A slug ending in "-alt" is kept on file but not shown.
MAP = {
    # Main series (16:9, navy band with gold title)
    "A New Beginning After Hardship.png": "past-evictions",
    "A Second Chance Together.png": "returning-citizens",
    "Family Finances Under Pressure.png": "credit-and-debt",
    "Gemini_Generated_Image_7gbk387gbk387gbk.jpg": "survivors-of-domestic-violence",
    "Gemini_Generated_Image_7u2olo7u2olo7u2o.jpg": "recovery-and-health",
    "Gemini_Generated_Image_byeyj0byeyj0byey.jpg": "experiencing-homelessness",
    "Gemini_Generated_Image_cwslqdcwslqdcwsl.jpg": "disabilities-and-assistance-animals",
    "Gemini_Generated_Image_f4w6v9f4w6v9f4w6.jpg": "immigrants-and-newcomers",
    "Gemini_Generated_Image_i63cmsi63cmsi63c.jpg": "every-age-every-identity",
    "Gemini_Generated_Image_o1zbfbo1zbfbo1zb.jpg": "first-time-renters",
    "Low Income, Shared Resilience.png": "low-or-irregular-income",
    "Veterans Second Chance Welcome.png": "veterans",
    "Vouchers & Benefits Community Support.png": "vouchers-and-benefits",
    # Earlier 4:3 posters, kept on file, not shown
    "Second Chances, Brighter Futures.png": "returning-citizens-alt",
    "Veterans Deserve a Place to Call Home.png": "veterans-alt",
    "A Fresh Start_ New Beginnings.png": "past-evictions-alt",
    "A Fresh Start Within Reach-2.png": "credit-and-debt-alt",
    "Second Chances, Brighter Futures-1.png": "credit-and-debt-alt2",
}


def main():
    os.makedirs(DST, exist_ok=True)
    for f in sorted(os.listdir(SRC)):
        if not f.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
            continue
        slug = MAP.get(f) or MAP.get(re.sub(r"[^ -~]", "", f).replace("  ", " "))
        if not slug:
            print(f"UNMATCHED: {f}  (look at it and add it to MAP)")
            continue
        out = os.path.join(DST, slug + ".jpg")
        im = Image.open(os.path.join(SRC, f)).convert("RGB")
        if im.width > 1200:
            im = im.resize((1200, round(im.height * 1200 / im.width)), Image.LANCZOS)
        im.save(out, "JPEG", quality=84, optimize=True, progressive=True)
        print(f"{slug:<28} <- {f}  ({os.path.getsize(out) // 1024} KB)")


if __name__ == "__main__":
    main()
