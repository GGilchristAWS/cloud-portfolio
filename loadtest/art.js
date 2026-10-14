// Pixel art for the dashboard's "Latency distribution" heatmap, used by the
// "art" scenario in scenarios.js: a named picture, or any short text.
//
// The heatmap has one row per latency bucket of the request histogram and one
// column per minute, and a cell's brightness is how many requests landed in
// it. /api/simulate answers with whatever latency it's asked for, so sending
// requests with latency X during minute Y lights the pixel (Y, X).

// One heatmap column per minute (the panel's 1m interval).
export const COLUMN_SECONDS = 60;

// Requests per second for a fully lit pixel. A pixel at brightness level L
// (0-5) gets L/5 of that.
export const RATE_PER_PIXEL = 5;

// A latency (ms) inside each histogram bucket, bottom row first. The buckets
// are the OpenTelemetry defaults: <5 ms, 5-10, 10-25, 25-50, 50-75, 75-100,
// 100-250, 250-500, 500-750, 750 ms-1 s, 1-2.5 s. Values sit away from the
// edges, so a few ms of server overhead can't push a request into the next row.
export const ROW_LATENCY_MS = [0, 6, 17, 37, 62, 87, 170, 370, 620, 870, 1700];

// 5x7 font, each glyph as 7 rows (top first) of 5 pixels.
const FONT = {
  A: "01110 10001 10001 11111 10001 10001 10001",
  B: "11110 10001 10001 11110 10001 10001 11110",
  C: "01110 10001 10000 10000 10000 10001 01110",
  D: "11110 10001 10001 10001 10001 10001 11110",
  E: "11111 10000 10000 11110 10000 10000 11111",
  F: "11111 10000 10000 11110 10000 10000 10000",
  G: "01110 10001 10000 10111 10001 10001 01111",
  H: "10001 10001 10001 11111 10001 10001 10001",
  I: "01110 00100 00100 00100 00100 00100 01110",
  J: "00111 00010 00010 00010 00010 10010 01100",
  K: "10001 10010 10100 11000 10100 10010 10001",
  L: "10000 10000 10000 10000 10000 10000 11111",
  M: "10001 11011 10101 10101 10001 10001 10001",
  N: "10001 10001 11001 10101 10011 10001 10001",
  O: "01110 10001 10001 10001 10001 10001 01110",
  P: "11110 10001 10001 11110 10000 10000 10000",
  Q: "01110 10001 10001 10001 10101 10010 01101",
  R: "11110 10001 10001 11110 10100 10010 10001",
  S: "01111 10000 10000 01110 00001 00001 11110",
  T: "11111 00100 00100 00100 00100 00100 00100",
  U: "10001 10001 10001 10001 10001 10001 01110",
  V: "10001 10001 10001 10001 10001 01010 00100",
  W: "10001 10001 10001 10101 10101 10101 01010",
  X: "10001 10001 01010 00100 01010 10001 10001",
  Y: "10001 10001 10001 01010 00100 00100 00100",
  Z: "11111 00001 00010 00100 01000 10000 11111",
  0: "01110 10001 10011 10101 11001 10001 01110",
  1: "00100 01100 00100 00100 00100 00100 01110",
  2: "01110 10001 00001 00010 00100 01000 11111",
  3: "11111 00010 00100 00010 00001 10001 01110",
  4: "00010 00110 01010 10010 11111 00010 00010",
  5: "11111 10000 11110 00001 00001 10001 01110",
  6: "00110 01000 10000 11110 10001 10001 01110",
  7: "11111 00001 00010 00100 01000 01000 01000",
  8: "01110 10001 10001 01110 10001 10001 01110",
  9: "01110 10001 10001 01111 00001 00010 01100",
  " ": "00000 00000 00000 00000 00000 00000 00000",
  "!": "00100 00100 00100 00100 00100 00000 00100",
  "-": "00000 00000 00000 11111 00000 00000 00000",
  "*": "00000 01010 11111 11111 01110 00100 00000", // a heart
};

// Pictures, 11 rows (top first) by any width, one minute per column. Each
// character is a brightness: " " dark, then . - ~ o * up to white-hot.
// Heatmap cells are about 3x wider than tall at a 45-minute range, so
// shapes are drawn narrow.
const SHADES = " .-~o*";
const PICTURES = {
  // After Van Gogh: the cypress, the swirling wind, haloed stars, the
  // crescent moon, and the village's lit windows under dark hills.
  "starry-night": [
    "....- -..-~-..........~*~........-~-...-~o*o-...",
    "-~-.- -..~*~..........-~-........~*~...-~*---...",
    "~*~-  ----~-....~oo.......~~.-----~---.-~*---...",
    "-~~~  ~~~~~~---.o~o.......oo~~~~~~~~~~~-~o*o-...",
    "~~--  -..---~~~-o--.o.---~o~-o--...--~-~~~---...",
    "-..-   -.....--~o~~o~~~~~-o~~~......~*~---~~~~~~",
    "...-   -.....-~-~ooo-----.~oo-~- ...-~-...---~*~",
    "...-   -.....~*~..~..........~*~ ............-~-",
    "                  ...........-~   .........     ",
    "               o      o      o        o      o  ",
    "            o      o      o       o       o     ",
  ],
};

const ROWS = ROW_LATENCY_MS.length; // 11
const TEXT_LEVEL = 5; // white-hot
const FRAME_LEVEL = 2; // dim orange

// Brightness (0-5) of every pixel, as grid[row][column] with row 0 at the
// bottom. `art` names a picture, or is text to write.
export function artGrid(art) {
  const picture = PICTURES[art.toLowerCase()];
  if (picture) {
    if (picture.length !== ROWS || new Set(picture.map((line) => line.length)).size !== 1) {
      throw new Error(`Picture "${art}" must be ${ROWS} rows of equal width`);
    }
    return picture.map((line) => [...line].map((ch) => SHADES.indexOf(ch))).reverse();
  }
  return textGrid(art);
}

// Text layout, top to bottom: frame, blank, 7 rows of text, blank, frame; and
// left to right: frame, blank, the text (1 blank column between letters),
// blank, frame. Unknown characters render as spaces; capped at 12 characters.
function textGrid(text) {
  const glyphs = [...text.toUpperCase().slice(0, 12)].map((ch) => (FONT[ch] || FONT[" "]).split(" "));
  const textWidth = glyphs.length * 6 - 1;
  const width = textWidth + 4;
  const grid = Array.from({ length: ROWS }, () => new Array(width).fill(0));

  for (let row = 0; row < ROWS; row++) {
    for (let col = 0; col < width; col++) {
      if (row === 0 || row === ROWS - 1 || col === 0 || col === width - 1) {
        grid[row][col] = FRAME_LEVEL;
        continue;
      }
      const glyphRow = 8 - row; // heatmap rows 8..2 hold font rows 0..6
      const textCol = col - 2;
      if (glyphRow < 0 || glyphRow > 6 || textCol < 0 || textCol >= textWidth) continue;
      const glyph = glyphs[Math.floor(textCol / 6)];
      const x = textCol % 6;
      if (x < 5 && glyph[glyphRow][x] === "1") grid[row][col] = TEXT_LEVEL;
    }
  }
  return grid;
}

// The grid as text, top row first, for the job log.
export function preview(grid) {
  return grid
    .map((cells) => cells.map((v) => SHADES[v]).join(""))
    .reverse()
    .join("\n");
}
