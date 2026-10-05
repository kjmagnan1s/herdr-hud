// Mockup controls: switch between the macOS glass and the opaque Windows look.
for (const [id, apply] of [['glass', on => document.documentElement.classList.toggle('glass', on)], ['game', on => document.body.classList.toggle('no-game', !on)]]) {
  const box = document.getElementById(id); box.onchange = () => apply(box.checked); apply(box.checked);
}
