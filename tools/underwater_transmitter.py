"""
BITSBlink Underwater Flashlight Transmitter

Simulates a flashlight beam transmitted through turbid water.
Renders scattered beam, suspended particles, caustic shimmer.
Same RS-encoded protocol, 204ms chip timing.
"""

import tkinter as tk
import time
import random
import math

# ══════════════════════════════════════════════════════════════════
#  GF(256) + RS (identical to transmitter.py)
# ══════════════════════════════════════════════════════════════════

PRIM = 0x11D
gf_exp = [0] * 512
gf_log = [0] * 256

def init_tables():
    x = 1
    for i in range(255):
        gf_exp[i] = x
        gf_log[x] = i
        x <<= 1
        if x & 256:
            x ^= PRIM
    for i in range(255, 512):
        gf_exp[i] = gf_exp[i - 255]

init_tables()

def gf_mul(x, y):
    if x == 0 or y == 0: return 0
    return gf_exp[gf_log[x] + gf_log[y]]

def gf_poly_mul(p, q):
    r = [0] * (len(p) + len(q) - 1)
    for j in range(len(q)):
        for i in range(len(p)):
            r[i + j] ^= gf_mul(p[i], q[j])
    return r

def rs_generator_poly(nsym):
    g = [1]
    for i in range(nsym):
        g = gf_poly_mul(g, [1, gf_exp[i]])
    return g

def rs_encode(data, nsym):
    gen = rs_generator_poly(nsym)
    msg_out = data + [0] * (len(gen) - 1)
    for i in range(len(data)):
        coef = msg_out[i]
        if coef != 0:
            for j in range(1, len(gen)):
                msg_out[i + j] ^= gf_mul(gen[j], coef)
    msg_out[:len(data)] = data
    return msg_out

# ══════════════════════════════════════════════════════════════════
#  PROTOCOL
# ══════════════════════════════════════════════════════════════════

PREAMBLE = [1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0]
SYNC     = [1,1,0,0,1,1,0,0]
CHIP_MS  = 204

def byte_to_bits(byte):
    return [(byte >> (7 - i)) & 1 for i in range(8)]

def encode(text):
    utf8 = list(text.encode('utf-8'))
    msg_len = len(utf8)
    if msg_len > 127:
        raise ValueError(f"Too long: {msg_len}")
    rs_encoded = rs_encode(utf8, msg_len)
    chips = []
    chips.extend(PREAMBLE)
    chips.extend(SYNC)
    chips.extend(byte_to_bits(msg_len))
    for b in rs_encoded:
        chips.extend(byte_to_bits(b))
    return chips

# ══════════════════════════════════════════════════════════════════
#  UNDERWATER RENDERING
# ══════════════════════════════════════════════════════════════════

DEEP_WATER = '#001a1a'


class UnderwaterTransmitter:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("🌊 Underwater TX")
        self.root.configure(bg='#0a0a0a')
        self.root.geometry("600x500")
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.transmitting = False
        self.alive = True
        self.canvas = None
        self.particles = []

        # ── Controls ──
        frame = tk.Frame(self.root, bg='#0a1a1a', padx=24, pady=18)
        frame.place(relx=0.5, rely=0.5, anchor='center')

        tk.Label(frame, text="🌊 UNDERWATER FLASHLIGHT TX",
                 font=("Consolas", 11, "bold"), fg='#44aa88', bg='#0a1a1a').pack(pady=(0,14))

        self.msg_var = tk.StringVar(value="hi")
        entry = tk.Entry(frame, textvariable=self.msg_var,
                         font=("Consolas", 22, "bold"), fg='#88ffee', bg='#001a1a',
                         insertbackground='#88ffee', justify='center',
                         relief='flat', highlightthickness=1,
                         highlightcolor='#44aa88', highlightbackground='#003333')
        entry.pack(fill='x', ipady=6)
        entry.bind('<Return>', lambda e: self.transmit())

        speed_frame = tk.Frame(frame, bg='#0a1a1a')
        speed_frame.pack(pady=(10,0))
        tk.Label(speed_frame, text="CHIP:", font=("Consolas", 10),
                 fg='#448877', bg='#0a1a1a').pack(side='left')
        self.speed_var = tk.StringVar(value="204")
        tk.Entry(speed_frame, textvariable=self.speed_var, width=5,
                 font=("Consolas", 13, "bold"), fg='#88ffee', bg='#001a1a',
                 justify='center', relief='flat',
                 highlightthickness=1, highlightbackground='#003333').pack(side='left', padx=5)
        tk.Label(speed_frame, text="ms", font=("Consolas", 10),
                 fg='#335544', bg='#0a1a1a').pack(side='left')

        self.btn = tk.Button(frame, text="▶  TRANSMIT", command=self.transmit,
                             font=("Consolas", 12, "bold"), fg='white', bg='#226655',
                             activebackground='#44aa88', activeforeground='white',
                             relief='flat', cursor='hand2', padx=20, pady=8)
        self.btn.pack(fill='x', pady=(14,0))

        self.status_var = tk.StringVar(value="Ready — underwater scattering simulation")
        tk.Label(frame, textvariable=self.status_var,
                 font=("Consolas", 9), fg='#446655', bg='#0a1a1a',
                 wraplength=440).pack(pady=(10,0))

        self.root.mainloop()

    def _on_close(self):
        self.alive = False
        self.root.destroy()

    def _generate_particles(self, w, h, count=200):
        self.particles = []
        for _ in range(count):
            x = random.randint(0, w)
            y = random.randint(0, h)
            size = random.uniform(1.5, 5)
            drift = random.uniform(0.3, 1.0)
            self.particles.append((x, y, size, drift))

    def _draw_underwater(self, w, h, beam_on):
        if not self.alive or self.canvas is None:
            return
        try:
            self.canvas.delete('all')
        except tk.TclError:
            self.alive = False
            return

        cx, cy = w // 2, h // 2
        max_dim = max(w, h)

        if beam_on:
            # ── BEAM ON: big, smooth, bright scattered blob ──

            # Smooth gradient: many concentric ovals from edge to center
            # Cover the full screen with the outer glow
            num_rings = 25
            max_radius = int(max_dim * 0.7)  # blob covers ~70% of screen

            for i in range(num_rings):
                frac = i / num_rings  # 0 = outermost, 1 = innermost
                radius = int(max_radius * (1 - frac))
                if radius < 5:
                    continue

                # Smooth brightness curve (quadratic ramp-up toward center)
                brightness = frac * frac  # quadratic = smoother than linear

                # Blue-green tinted light (underwater absorption)
                r = int(140 * brightness + 30)
                g = int(255 * brightness + 40)
                b = int(230 * brightness + 40)
                r = min(r, 255)
                g = min(g, 255)
                b = min(b, 255)
                color = f'#{r:02x}{g:02x}{b:02x}'

                # Slight wobble for organic feel
                jx = random.randint(-2, 2)
                jy = random.randint(-2, 2)

                self.canvas.create_oval(
                    cx - radius + jx, cy - radius + jy,
                    cx + radius + jx, cy + radius + jy,
                    fill=color, outline='')

            # Bright core — large and prominent
            core_r = int(max_dim * 0.12)
            jr = random.randint(-2, 2)
            self.canvas.create_oval(
                cx - core_r + jr, cy - core_r,
                cx + core_r + jr, cy + core_r,
                fill='#bbffee', outline='')

            # Inner hotspot
            hot_r = int(max_dim * 0.05)
            self.canvas.create_oval(
                cx - hot_r, cy - hot_r,
                cx + hot_r, cy + hot_r,
                fill='#ddfff8', outline='')

            # Caustic rays — longer, thinner
            for _ in range(12):
                angle = random.uniform(0, 2 * math.pi)
                length = random.randint(int(max_dim * 0.15), int(max_dim * 0.45))
                x1 = cx + int(30 * math.cos(angle))
                y1 = cy + int(30 * math.sin(angle))
                x2 = cx + int(length * math.cos(angle))
                y2 = cy + int(length * math.sin(angle))
                self.canvas.create_line(x1, y1, x2, y2,
                                        fill='#66eebb', width=1, stipple='gray50')

            # Illuminated particles
            for (px, py, size, drift) in self.particles:
                dist = math.sqrt((px - cx)**2 + (py - cy)**2)
                if dist < max_radius:
                    brightness = (1 - dist / max_radius) * drift
                    if brightness > 0.1:
                        gv = int(220 * brightness)
                        bv = int(200 * brightness)
                        rv = int(150 * brightness)
                        col = f'#{min(rv,255):02x}{min(gv,255):02x}{min(bv,255):02x}'
                        s = size * (0.8 + brightness * 0.6)
                        self.canvas.create_oval(px-s, py-s, px+s, py+s,
                                                fill=col, outline='')

        else:
            # ── BEAM OFF: dark water ──
            # Dark background already set by canvas bg
            for (px, py, size, drift) in self.particles:
                if random.random() < 0.25:
                    dim = int(25 * drift)
                    col = f'#{dim:02x}{dim+8:02x}{dim+8:02x}'
                    self.canvas.create_oval(px-size*0.4, py-size*0.4,
                                            px+size*0.4, py+size*0.4,
                                            fill=col, outline='')

        try:
            self.canvas.update()
        except tk.TclError:
            self.alive = False

    def transmit(self):
        if self.transmitting or not self.alive:
            return
        self.transmitting = True

        text = self.msg_var.get()
        if not text:
            self.transmitting = False
            return

        chip_ms = int(self.speed_var.get() or 204)
        chip_sec = chip_ms / 1000.0
        chips = encode(text)

        self.status_var.set(f'TX: "{text}" — {len(chips)} chips @ {chip_ms}ms')
        self.btn.config(state='disabled', text="■  TRANSMITTING…", bg='#335544')
        self.root.update()

        # Go fullscreen
        self.root.attributes('-fullscreen', True)
        self.root.update()

        w = self.root.winfo_screenwidth()
        h = self.root.winfo_screenheight()
        self.canvas = tk.Canvas(self.root, width=w, height=h,
                                bg=DEEP_WATER, highlightthickness=0)
        self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
        self._generate_particles(w, h, 250)
        self.root.update()
        time.sleep(0.2)

        # 500ms dark lead-in
        self._draw_underwater(w, h, beam_on=False)
        self._busy_wait(0.5)

        # Flash each chip
        for chip in chips:
            if not self.alive:
                break
            self._draw_underwater(w, h, beam_on=(chip == 1))
            self._busy_wait(chip_sec)

        # 500ms dark tail
        self._draw_underwater(w, h, beam_on=False)
        self._busy_wait(0.5)

        # Restore
        if self.alive:
            try:
                if self.canvas:
                    self.canvas.destroy()
                    self.canvas = None
                self.root.attributes('-fullscreen', False)
                self.root.configure(bg='#0a0a0a')
                self.btn.config(state='normal', text="▶  TRANSMIT", bg='#226655')
                self.status_var.set(f'✓ Sent "{text}" ({len(chips)} chips)')
                self.root.update()
            except tk.TclError:
                pass
        self.transmitting = False

    def _busy_wait(self, seconds):
        end = time.perf_counter() + seconds
        while time.perf_counter() < end:
            pass


if __name__ == '__main__':
    UnderwaterTransmitter()
