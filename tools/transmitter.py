"""
BITSBlink Screen Transmitter with Reed-Solomon Error Correction

Encodes: text → UTF-8 → RS(nsym=len) → preamble + sync + len + data+parity
Uses GF(256) with primitive polynomial 0x11D to match Dart decoder.

Protocol:
  PREAMBLE: 20 alternating chips (10101010101010101010)
  SYNC:     11001100 (8 chips)
  LENGTH:   8 bits (ORIGINAL data byte count, before RS)
  DATA+PAR: (length * 2) × 8 bits (data bytes + parity bytes)

The receiver reads the length byte, knows parity = length (1:1 ratio),
reads length*2 total bytes, and runs RS correction.
"""

import tkinter as tk
import time

# ══════════════════════════════════════════════════════════════════
#  GF(256) ARITHMETIC — matches galois_field.dart exactly
# ══════════════════════════════════════════════════════════════════

PRIM = 0x11D  # primitive polynomial x^8 + x^4 + x^3 + x^2 + 1

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

def gf_div(x, y):
    if y == 0: raise ZeroDivisionError
    if x == 0: return 0
    return gf_exp[(gf_log[x] + 255 - gf_log[y]) % 255]

def gf_poly_mul(p, q):
    r = [0] * (len(p) + len(q) - 1)
    for j in range(len(q)):
        for i in range(len(p)):
            r[i + j] ^= gf_mul(p[i], q[j])
    return r

# ══════════════════════════════════════════════════════════════════
#  REED-SOLOMON ENCODER — matches reed_solomon.dart exactly
# ══════════════════════════════════════════════════════════════════

def rs_generator_poly(nsym):
    g = [1]
    for i in range(nsym):
        g = gf_poly_mul(g, [1, gf_exp[i]])
    return g

def rs_encode(data, nsym):
    """Encode data with nsym parity symbols. Returns data + parity."""
    gen = rs_generator_poly(nsym)
    msg_out = data + [0] * (len(gen) - 1)
    for i in range(len(data)):
        coef = msg_out[i]
        if coef != 0:
            for j in range(1, len(gen)):
                msg_out[i + j] ^= gf_mul(gen[j], coef)
    # Replace data portion (it gets modified during division)
    msg_out[:len(data)] = data
    return msg_out

# ══════════════════════════════════════════════════════════════════
#  PROTOCOL — matches encoder_service.dart
# ══════════════════════════════════════════════════════════════════

PREAMBLE = [1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0]  # 20 chips
SYNC     = [1,1,0,0,1,1,0,0]                              # 8 chips
CHIP_MS  = 200  # 200ms per chip

def byte_to_bits(byte):
    return [(byte >> (7 - i)) & 1 for i in range(8)]

def encode(text):
    """Encode text → UTF-8 → RS → chip signal."""
    utf8 = list(text.encode('utf-8'))
    msg_len = len(utf8)

    if msg_len > 127:
        raise ValueError(f"Too long: {msg_len} bytes (max 127)")

    # RS encode with 1:1 parity (nsym = msg_len)
    rs_encoded = rs_encode(utf8, msg_len)
    # rs_encoded = data (msg_len bytes) + parity (msg_len bytes) = 2×msg_len bytes

    chips = []
    chips.extend(PREAMBLE)                     # 20 chips
    chips.extend(SYNC)                         # 8 chips
    chips.extend(byte_to_bits(msg_len))        # 8 chips (original length)
    for b in rs_encoded:
        chips.extend(byte_to_bits(b))          # (msg_len * 2) × 8 chips

    return chips, utf8, rs_encoded

# ══════════════════════════════════════════════════════════════════
#  GUI
# ══════════════════════════════════════════════════════════════════

class TransmitterApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("BITSBlink TX + RS")
        self.root.configure(bg='#0a0a0a')
        self.root.geometry("520x400")
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.transmitting = False
        self.alive = True

        frame = tk.Frame(self.root, bg='#141414', padx=30, pady=20)
        frame.place(relx=0.5, rely=0.5, anchor='center')

        tk.Label(frame, text="⚡ BITSBLINK TX + RS ECC",
                 font=("Consolas", 11, "bold"), fg='#888', bg='#141414').pack(pady=(0,14))

        self.msg_var = tk.StringVar(value="hi")
        entry = tk.Entry(frame, textvariable=self.msg_var,
                         font=("Consolas", 22, "bold"), fg='#4CAF50', bg='#1a1a1a',
                         insertbackground='#4CAF50', justify='center',
                         relief='flat', highlightthickness=1,
                         highlightcolor='#4CAF50', highlightbackground='#333')
        entry.pack(fill='x', ipady=6)
        entry.bind('<Return>', lambda e: self.transmit())

        speed_frame = tk.Frame(frame, bg='#141414')
        speed_frame.pack(pady=(10,0))
        tk.Label(speed_frame, text="CHIP:", font=("Consolas", 10),
                 fg='#888', bg='#141414').pack(side='left')
        self.speed_var = tk.StringVar(value="200")
        tk.Entry(speed_frame, textvariable=self.speed_var, width=5,
                 font=("Consolas", 13, "bold"), fg='#4CAF50', bg='#1a1a1a',
                 justify='center', relief='flat',
                 highlightthickness=1, highlightbackground='#333').pack(side='left', padx=5)
        tk.Label(speed_frame, text="ms", font=("Consolas", 10),
                 fg='#555', bg='#141414').pack(side='left')

        self.btn = tk.Button(frame, text="▶  TRANSMIT", command=self.transmit,
                             font=("Consolas", 12, "bold"), fg='white', bg='#2E7D32',
                             activebackground='#4CAF50', activeforeground='white',
                             relief='flat', cursor='hand2', padx=20, pady=8)
        self.btn.pack(fill='x', pady=(14,0))

        self.status_var = tk.StringVar(value="Ready — RS(1:1 parity) · 200ms/chip")
        tk.Label(frame, textvariable=self.status_var,
                 font=("Consolas", 9), fg='#666', bg='#141414',
                 wraplength=440).pack(pady=(10,0))

        self.preview_var = tk.StringVar()
        tk.Label(frame, textvariable=self.preview_var,
                 font=("Consolas", 7), fg='#444', bg='#141414',
                 wraplength=460, justify='left').pack(pady=(6,0))

        self.update_preview()
        self.msg_var.trace_add('write', lambda *a: self.update_preview())
        self.root.mainloop()

    def _on_close(self):
        self.alive = False
        self.root.destroy()

    def update_preview(self):
        try:
            chips, utf8, rs_enc = encode(self.msg_var.get() or "")
            chip_ms = int(self.speed_var.get() or 200)
            dur = len(chips) * chip_ms / 1000
            self.preview_var.set(
                f"UTF-8: {utf8}\n"
                f"RS:    {rs_enc}\n"
                f"Chips: {''.join(str(c) for c in chips[:28])}|{''.join(str(c) for c in chips[28:])}")
            self.status_var.set(
                f"{len(chips)} chips · {dur:.1f}s · "
                f"{len(utf8)}B data + {len(utf8)}B parity = {len(rs_enc)}B total")
        except Exception as e:
            self.preview_var.set(str(e))

    def transmit(self):
        if self.transmitting or not self.alive:
            return
        self.transmitting = True

        text = self.msg_var.get()
        if not text:
            self.transmitting = False
            return

        chip_ms = int(self.speed_var.get() or 200)
        chip_sec = chip_ms / 1000.0
        chips, utf8, rs_enc = encode(text)

        self.status_var.set(f'TX: "{text}" — {len(chips)} chips @ {chip_ms}ms (RS protected)')
        self.btn.config(state='disabled', text="■  TRANSMITTING…", bg='#555')
        self.root.update()

        self.root.attributes('-fullscreen', True)
        self.root.update()
        time.sleep(0.2)

        # 500ms dark lead-in
        self._flash('black')
        self._busy_wait(0.5)

        # Flash each chip
        for chip in chips:
            if not self.alive:
                break
            self._flash('#ffffff' if chip else '#000000')
            self._busy_wait(chip_sec)

        # 500ms dark tail
        self._flash('black')
        self._busy_wait(0.5)

        if self.alive:
            try:
                self.root.attributes('-fullscreen', False)
                self.root.configure(bg='#0a0a0a')
                self.btn.config(state='normal', text="▶  TRANSMIT", bg='#2E7D32')
                self.status_var.set(f'✓ Sent "{text}" ({len(chips)} chips, RS protected)')
                self.root.update()
            except tk.TclError:
                pass
        self.transmitting = False

    def _flash(self, color):
        if not self.alive: return
        try:
            self.root.configure(bg=color)
            self.root.update()
        except tk.TclError:
            self.alive = False

    def _busy_wait(self, seconds):
        end = time.perf_counter() + seconds
        while time.perf_counter() < end:
            pass

if __name__ == '__main__':
    TransmitterApp()
