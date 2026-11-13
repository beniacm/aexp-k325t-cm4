#!/usr/bin/env python3
"""menu_gen.py -- the Amiga core's menu definition for the Linux shell, generated from the core.

Reads the M2M configuration of an AExp checkout (CORE/vhdl/config.vhd, the C_MENU_* constants of
CORE/vhdl/mega65.vhd, the HDMI filter table of CORE/m2m-rom/m2m-rom.asm, the polyphase coefficient
tables of CORE/m2m-rom/video_filters and M2M/video_filters, the ascal mode values of
M2M/rom/sysdef.asm) and writes, in one step:

  * the menu data file (JSON, sorted keys, no timestamps: the same input always gives the same bytes)
    that travels with the bitstream under the same base name (<bitstream>.menu);
  * its 32-bit id = CRC-32 (zlib / IEEE 802.3) of exactly those bytes;
  * the 16 factory-default CFM words (OPTM_G_STDSEL: bit n of word w = menu line 16w+n);
  * optionally (--vhdl) a VHDL package with both, for the host build's registers 0xFFF9/A, 0xFFC0..CF.

    menu_gen.py AEXP_DIR OUT.menu [--vhdl OUT.vhd]

The id and the defaults are also printed (one line each), so a build script can log them.
This is the Linux side's single source of the menu: the QNICE CONFIG ROM (device 0x0002) does not
exist in the host build.  Characters are kept as code points of the M2M font (Anikki 16x16, Latin-1
range), e.g. 196 = horizontal line; JSON escapes them (ensure_ascii).
"""

import json
import os
import re
import sys
import zlib

FORMAT = 1

# ---------------------------------------------------------------------------------------------
# A small evaluator for the constant expressions of config.vhd: string and character literals,
# integers (decimal, 16#..#), names of other constants, '&' (concatenation), '+', '-', '*', '/',
# X'length, character'val(n), true/false, positional and named aggregates.  Anything else makes
# that one constant unevaluable (it is skipped unless the generator needs it).
# ---------------------------------------------------------------------------------------------

_TOK = re.compile(r'''
    (?P<str>"(?:[^"]|"")*")
  | (?P<bitstr>[xXbB]"[0-9A-Fa-f_]*")
  | (?P<based>\d+\#[0-9A-Fa-f_]+\#)
  | (?P<num>\d+)
  | (?P<chr>'[^']')(?!\w)
  | (?P<name>[A-Za-z][A-Za-z0-9_]*)
  | (?P<arrow>=>)
  | (?P<op>[&+\-*/(),'])
  | (?P<ws>\s+)
''', re.X)


class Unevaluable(Exception):
    pass


def _strip_comments(text):
    out = []
    for line in text.splitlines():
        res, i, in_str = [], 0, False
        while i < len(line):
            c = line[i]
            if c == '"':
                in_str = not in_str
            elif not in_str and line.startswith('--', i):
                break
            res.append(c)
            i += 1
        out.append(''.join(res))
    return '\n'.join(out)


def _tokens(expr):
    pos, toks = 0, []
    while pos < len(expr):
        m = _TOK.match(expr, pos)
        if not m:
            raise Unevaluable('cannot tokenise at %r' % expr[pos:pos + 20])
        pos = m.end()
        kind = m.lastgroup
        if kind != 'ws':
            toks.append((kind, m.group()))
    return toks


class Evaluator:
    def __init__(self, sources):
        self.raw = {}
        for text in sources:
            text = _strip_comments(text)
            for m in re.finditer(r'\bconstant\s+(\w+)\s*:\s*[^:;]*?:=\s*', text, re.I):
                name, start = m.group(1), m.end()
                # the expression ends at the first ';' outside string literals
                i, in_str = start, False
                while i < len(text):
                    if text[i] == '"':
                        in_str = not in_str
                    elif text[i] == ';' and not in_str:
                        break
                    i += 1
                self.raw.setdefault(name.upper(), text[start:i])
        self.cache = {}

    def get(self, name):
        key = name.upper()
        if key in self.cache:
            return self.cache[key]
        if key not in self.raw:
            raise Unevaluable('unknown constant ' + name)
        self.cache[key] = None                  # recursion guard
        try:
            val = self.eval(self.raw[key])
        except Unevaluable:
            del self.cache[key]
            raise
        self.cache[key] = val
        return val

    def eval(self, expr):
        saved = getattr(self, 't', None), getattr(self, 'i', 0)   # nested get() of another constant
        self.t, self.i = _tokens(expr), 0
        try:
            v = self._expr()
            if self.i != len(self.t):
                raise Unevaluable('trailing tokens in %r' % expr[:40])
            return v
        finally:
            self.t, self.i = saved

    def _peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def _take(self, text=None):
        tok = self._peek()
        if text is not None and tok[1] != text:
            raise Unevaluable('expected %r got %r' % (text, tok[1]))
        self.i += 1
        return tok

    def _expr(self):
        v = self._term()
        while self._peek()[1] in ('&', '+', '-'):
            op = self._take()[1]
            w = self._term()
            if op == '&':
                v = _as_str(v) + _as_str(w)
            elif op == '+':
                v = v + w
            else:
                v = v - w
        return v

    def _term(self):
        v = self._factor()
        while self._peek()[1] in ('*', '/'):
            op = self._take()[1]
            w = self._factor()
            v = v * w if op == '*' else v // w
        return v

    def _factor(self):
        kind, text = self._take()
        if kind == 'str':
            return text[1:-1].replace('""', '"')
        if kind == 'chr':
            return text[1]
        if kind == 'num':
            return int(text)
        if kind == 'based':
            base, digits = text[:-1].split('#')
            return int(digits.replace('_', ''), int(base))
        if kind == 'bitstr':
            raise Unevaluable('bit string')
        if text == '(':
            return self._aggregate()
        if text == '-':
            return -self._factor()
        if kind == 'name':
            low = text.lower()
            if low in ('true', 'false'):
                return low == 'true'
            if low == 'character' and self._peek()[1] == "'":
                self._take("'")
                attr = self._take()[1].lower()
                if attr != 'val':
                    raise Unevaluable("character'" + attr)
                self._take('(')
                n = self._expr()
                self._take(')')
                return chr(n)
            if self._peek()[1] == "'":
                self._take("'")
                attr = self._take()[1].lower()
                if attr != 'length':
                    raise Unevaluable("'" + attr)
                return len(_as_str(self.get(text)))
            if self._peek()[1] == '(':
                raise Unevaluable('function call ' + text)
            return self.get(text)
        raise Unevaluable('unexpected token %r' % text)

    def _aggregate(self):
        items, named = [], {}
        while True:
            if self._peek()[0] == 'name' and self.i + 1 < len(self.t) and self.t[self.i + 1][0] == 'arrow':
                key = self._take()[1].lower()
                self._take('=>')
                named[key] = self._expr()
            else:
                items.append(self._expr())
            sep = self._take()[1]
            if sep == ')':
                break
            if sep != ',':
                raise Unevaluable('bad aggregate separator %r' % sep)
        if named and items:
            raise Unevaluable('mixed aggregate')
        if named:
            return named
        if len(items) == 1 and not isinstance(items[0], (list, dict)):
            return items[0]                     # a parenthesised expression
        return items


def _as_str(v):
    if isinstance(v, str):
        return v
    raise Unevaluable('not a string: %r' % (v,))


# ---------------------------------------------------------------------------------------------
# QNICE assembler data: labels with .DW lists (coefficient tables, the filter table), .EQU values
# ---------------------------------------------------------------------------------------------

def _asm_number(tok, equ):
    tok = tok.strip()
    if re.fullmatch(r'0[xX][0-9A-Fa-f]+', tok):
        return int(tok, 16)
    if re.fullmatch(r'-?\d+', tok):
        return int(tok)
    if tok in equ:
        return equ[tok]
    raise KeyError(tok)


def read_equ(path):
    equ = {}
    for line in open(path, encoding='latin-1'):
        m = re.match(r'^([A-Za-z_$][\w$]*)\s+\.EQU\s+(\S+)', line)
        if m:
            try:
                equ[m.group(1)] = _asm_number(m.group(2), equ)
            except KeyError:
                pass
    return equ


def read_dw_tables(path):
    """{label: [words]} for every label followed by .DW lines (QNICE 16-bit words)."""
    tables, label = {}, None
    for line in open(path, encoding='latin-1'):
        line = line.split(';')[0].rstrip()
        if not line.strip():
            continue
        m = re.match(r'^([A-Za-z_][\w$]*)\s*(.*)$', line)
        if m and not line[0].isspace():
            label, rest = m.group(1), m.group(2).strip()
            tables[label] = []
            line = rest
            if not line:
                continue
        dw = re.match(r'^\s*\.DW\s+(.*)$', line, re.I)
        if dw and label is not None:
            tables[label].extend(x.strip() for x in dw.group(1).split(',') if x.strip())
    return tables


# ---------------------------------------------------------------------------------------------

def generate(aexp):
    core = os.path.join(aexp, 'CORE')
    cfg_text = open(os.path.join(core, 'vhdl', 'config.vhd'), encoding='latin-1').read()
    top_text = open(os.path.join(core, 'vhdl', 'mega65.vhd'), encoding='latin-1').read()
    ev = Evaluator([cfg_text])
    top = Evaluator([top_text])

    size = ev.get('OPTM_SIZE')
    items = ev.get('OPTM_ITEMS')
    if not items.endswith('\\n'):
        raise SystemExit('OPTM_ITEMS does not end with \\n')
    lines = items[:-2].split('\\n')
    groups = ev.get('OPTM_GROUPS')
    if len(lines) != size or len(groups) != size:
        raise SystemExit('menu size mismatch: OPTM_SIZE %d, %d items, %d groups'
                         % (size, len(lines), len(groups)))

    # factory defaults: OPTM_G_STDSEL = bit 8 of each group word (config.vhd SEL_OPTM_STDSEL)
    defaults = [0] * 16
    for n, g in enumerate(groups):
        if g & 0x100:
            defaults[n // 16] |= 1 << (n % 16)

    whs = ev.get('WHS')
    whs_data = ev.get('WHS_DATA')
    help_sets = []
    for rec in whs:
        pages = []
        for p in range(rec['page_count']):
            s, l = rec['page_start'][p], rec['page_length'][p]
            pages.append(whs_data[s:s + l])
        help_sets.append(pages)

    core_groups = {}
    for name in ev.raw:
        if name.startswith('OPTM_G_'):
            try:
                v = ev.get(name)
            except Unevaluable:
                continue
            if isinstance(v, int) and 0 < v < 0xFF:
                core_groups[name[len('OPTM_G_'):]] = v

    c_menu = {}
    for name in top.raw:
        if name.startswith('C_MENU_'):
            try:
                v = top.get(name)
            except Unevaluable:
                continue
            if isinstance(v, int):
                c_menu[name[len('C_MENU_'):]] = v

    general = {}
    for name in ('SAVE_SETTINGS', 'OPTM_PAUSE', 'WELCOME_ACTIVE', 'WELCOME_AT_RESET',
                 'KEYBOARD_AT_RESET', 'JOY_1_AT_RESET', 'JOY_2_AT_RESET', 'KEYBOARD_AT_OSD',
                 'JOY_1_AT_OSD', 'JOY_2_AT_OSD', 'RESET_COUNTER', 'ASCAL_USAGE',
                 'VD_ANTI_THRASHING_DELAY', 'VD_ITERATION_SIZE'):
        general[name.lower()] = ev.get(name)

    # HDMI filter dispatcher table + the coefficient tables it names
    rom = os.path.join(core, 'm2m-rom')
    sysdef = read_equ(os.path.join(aexp, 'M2M', 'rom', 'sysdef.asm'))
    filt_len = read_equ(os.path.join(aexp, 'M2M', 'rom', 'filters.asm')).get('ASCAL_FILTER_LEN', 0x100)
    rom_tables = read_dw_tables(os.path.join(rom, 'm2m-rom.asm'))
    coeff_files = []
    for d in (os.path.join(rom, 'video_filters'), os.path.join(aexp, 'M2M', 'video_filters')):
        if os.path.isdir(d):
            coeff_files += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith('.asm')]
    coeff = {}
    for f in coeff_files:
        for label, words in read_dw_tables(f).items():
            coeff.setdefault(label, words)
    flt_raw = rom_tables['HDMI_FLT_TABLE']
    if len(flt_raw) % 4:
        raise SystemExit('HDMI_FLT_TABLE is not rows of 4')
    filters, used = [], {}
    for r in range(0, len(flt_raw), 4):
        bit_sym, mode_sym, h_sym, v_sym = flt_raw[r:r + 4]
        if not bit_sym.startswith('AEXP_OSM_'):
            raise SystemExit('unexpected filter bit symbol ' + bit_sym)
        row = {'line': c_menu[bit_sym[len('AEXP_OSM_'):]],
               'ascal_mode': sysdef[mode_sym],
               'h': None if h_sym == '0' else h_sym,
               'v': None if v_sym == '0' else v_sym}
        for lab in (row['h'], row['v']):
            if lab is not None and lab not in used:
                words = [_asm_number(w, {}) for w in coeff[lab]]
                if len(words) < filt_len:
                    raise SystemExit('coefficient table %s has %d words < %d' % (lab, len(words), filt_len))
                used[lab] = words[:filt_len]
        filters.append(row)

    menu = {
        'format': FORMAT,
        'core_name': ev.get('CORENAME'),
        'core_version': ev.get('CORE_VERSION'),
        'cfg_file': ev.get('CFG_FILE'),
        'dir_start': ev.get('DIR_START'),
        'optm_dx': ev.get('OPTM_DX'),
        'optm_dy': ev.get('OPTM_DY'),
        'size': size,
        'items': lines,
        'groups': groups,
        'defaults': defaults,
        'strings': {'mount': ev.get('OPTM_S_MOUNT'), 'crtrom': ev.get('OPTM_S_CRTROM'),
                    'saving': ev.get('OPTM_S_SAVING')},
        'help': help_sets,
        'general': general,
        'core_groups': core_groups,
        'c_menu': c_menu,
        'filters': filters,
        'filter_tables': used,
        'ascal': {k[len('M2M$ASCAL_'):].lower(): v for k, v in sysdef.items() if k.startswith('M2M$ASCAL_')},
    }
    data = (json.dumps(menu, sort_keys=True, ensure_ascii=True, indent=1) + '\n').encode('ascii')
    return data, zlib.crc32(data) & 0xFFFFFFFF, defaults


def vhdl_package(menu_id, defaults):
    words = ',\n'.join('      x"%04X"' % w for w in defaults)
    return ('-- generated by menu_gen.py (Linux shell menu definition); do not edit\n'
            'library ieee;\nuse ieee.std_logic_1164.all;\n\n'
            'package host_menu_pkg is\n'
            '   type t_cfm_defaults is array (0 to 15) of std_logic_vector(15 downto 0);\n'
            '   constant C_HOST_MENU_ID      : std_logic_vector(31 downto 0) := x"%08X";\n'
            '   constant C_HOST_CFM_DEFAULTS : t_cfm_defaults := (\n%s\n   );\n'
            'end package host_menu_pkg;\n' % (menu_id, words))


def main(argv):
    args = list(argv[1:])
    vhdl = None
    if '--vhdl' in args:
        i = args.index('--vhdl')
        vhdl = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        sys.stderr.write(__doc__)
        return 2
    data, menu_id, defaults = generate(args[0])
    with open(args[1], 'wb') as f:
        f.write(data)
    if vhdl:
        with open(vhdl, 'w') as f:
            f.write(vhdl_package(menu_id, defaults))
    print('MENU_ID=%08X' % menu_id)
    print('CFM_DEFAULTS=' + ' '.join('%04X' % w for w in defaults))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
