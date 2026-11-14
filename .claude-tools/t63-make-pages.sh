#!/bin/sh
# Writes the three T6.3 pages (same shell, different data-plan, title and lead).
set -eu
cd "$(dirname "$0")/.."
make() {
  dir="site/mirror/my-mirror/$1"; mkdir -p "$dir"
  cat > "$dir/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>$2 | The Human Mirror</title>
<link rel="icon" href="/favicon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=Source+Serif+4:opsz,wght@8..60,600&display=swap">
<link rel="stylesheet" href="/mirror/assets/mirror.css?v=20261113l">
</head>
<body data-area="my" data-plan="$1">
<!-- Phase 6 (T6.3): goals by stage, steps and milestones. One module draws all three pages (plan-page.js). -->
<main id="main" class="mm-main">
  <div class="mm-read">
    <p class="mm-eyebrow"><a href="/mirror/my-mirror/">My Mirror</a></p>
    <h1>$2</h1>
    <p class="mm-lead">$3</p>
  </div>
  <div id="mmBox"><p role="status">Loading…</p></div>
</main>
<script type="module" src="/mirror/assets/mirror-ui.js?v=20261113h"></script>
<script type="module">
import { planPage } from "/mirror/assets/plan-page.js?v=20261113a";
planPage();
</script>
</body>
</html>
EOF
}
make plan "My plan" "The goals you choose for your life, sorted by stage. You decide what goes here, and you can change it any time."
make actions "My steps" "The small steps that get you there: what you're doing, and what others are doing for you."
make milestones "My milestones" "What you have done along the way. Every one of them counts."
ls site/mirror/my-mirror/plan site/mirror/my-mirror/actions site/mirror/my-mirror/milestones
