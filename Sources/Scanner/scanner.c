// MapDash game-list scanner.
//
// Hard rule: the game process is only ever READ (task_for_pid + mach_vm_read). Never write to it,
// never suspend it, never attach a debugger - an lldb attach once dropped the Battle.net session.
//
// task_for_pid works without root because the game binary carries get-task-allow and macOS lets
// members of _developer (which nests the admin group by default) take such task ports.
//
// Three independent ways to see a lobby, so that one game patch does not blind MapDash:
//
// A  The lobby object (4-byte aligned). Carries the name; its layout is the game's own and
//    changed with 3.0.1, which is what broke 0.4.0.
//      -16 .. -1   game 3.0.1+: 01000000 followed by three small counters
//      +0  .. +31  lobby name, NUL terminated, 32-byte buffer
//      +32 .. +47  game 3.0.0: 00000000 01000000 01000000 00000000
//                  game 3.0.1+: all zero (measured on 3.0.1.24371: 69 of 69 live lobbies)
//      +48         the statstring (below)
//    Sixteen zero bytes alone are far too common to anchor on, so the 3.0.1 form also needs the
//    1 in front of the name.
//
// B  The statstring on its own. W3 encoded (a mask byte before every 7 bytes): 13 bytes
//    flags/size/crc, map path NUL, host NUL, 0x00, 20-byte raw SHA-1 of the map file. This is the
//    Battle.net game-list format, older than Reforged, so it does not depend on the client's
//    object layout. The path starts at decoded byte 13, which pins its encoded form: mask, 7 bytes,
//    mask, 6 bytes, 'M', mask, "aqs/" ('p' is even and always encodes as 'q'). Only paths that
//    start with "Maps/" are seen this way; A also finds others.
//
// C  The game's own lobby list, a JSON message for its UI ("mapFile", "playerHost", "name").
//    No SHA-1, and old copies linger, so it never adds a lobby by itself. It confirms a B-only
//    statstring (otherwise freed statstrings of closed lobbies would come back) and supplies
//    its name, and its size tells the app whether the list is open at all.
//
// Measured on 3.0.1.24371, one snapshot of the fast regions: A 105, B 116 (all 105 of A among
// them), B without A 11 of which 2 listed, C 188 distinct (stale copies included).
// Freed objects of closed lobbies can linger, so a scan may still include a few stale lobbies.
#include "scanner.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GAME_SUFFIX "/Warcraft III.app/Contents/MacOS/Warcraft III"
// Measured on an M4 (game under Rosetta): all 79 of 79 objects sat in untagged read-write
// regions of at most 0.3 MB. Scanning only those is ~4x cheaper; callers cross-check with a
// periodic full scan because this is an observation, not a guarantee.
#define FAST_MAX_REGION (4ULL << 20)
#define STAT_MAX 512
#define MAX_LISTED 2048
#define MAX_CANDIDATES 1024

static const unsigned char HDR[16] = {0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0};
static const unsigned char ZERO[16] = {0};
static const unsigned char PRE[4] = {1, 0, 0, 0};

typedef struct {
  char path[260];
  char host[64];
  char name[33];
} listed_t;

typedef struct {
  listed_t *listed;
  int nlisted;
  md_game_t *cand;  // B-only statstrings, resolved against the list after the walk
  int ncand;
  md_stats_t st;
} scan_t;

// o is the offset of the +32 header; the lobby name starts 32 bytes before it.
static int is_header(const unsigned char *p, size_t o) {
  if (!memcmp(p + o, HDR, 16)) return 1;
  return o >= 48 && !memcmp(p + o, ZERO, 16) && !memcmp(p + o - 48, PRE, 4) && p[o - 32] != 0 &&
         (p[o + 16] & 1);  // the statstring's first mask byte always has bit 0 set
}

static size_t decode(const unsigned char *in, size_t n, unsigned char *out, size_t cap) {
  size_t i = 0, o = 0;
  while (i < n && o < cap) {
    unsigned char mask = in[i++];
    if (mask == 0) break;
    for (int k = 0; k < 7 && i < n && o < cap; k++) {
      unsigned char c = in[i++];
      out[o++] = (mask & (1 << (k + 1))) ? c : (unsigned char)(c - 1);
    }
  }
  return o;
}

pid_t md_find_game(void) {
  int cap = proc_listallpids(NULL, 0) + 64;
  pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
  if (!pids) return 0;
  int n = proc_listallpids(pids, cap * (int)sizeof(pid_t));
  pid_t found = 0;
  char path[PROC_PIDPATHINFO_MAXSIZE];
  size_t sl = strlen(GAME_SUFFIX);
  for (int i = 0; i < n && !found; i++) {
    if (pids[i] <= 0 || proc_pidpath(pids[i], path, sizeof path) <= 0) continue;
    size_t pl = strlen(path);
    if (pl < sl || strcmp(path + pl - sl, GAME_SUFFIX) != 0) continue;
    // With fast user switching another account's game can run at the same time. Its maps belong
    // in that account's folder, and its task port is not ours to take anyway.
    struct proc_bsdinfo bsd;
    if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bsd, PROC_PIDTBSDINFO_SIZE) != PROC_PIDTBSDINFO_SIZE) continue;
    if (bsd.pbi_uid == getuid()) found = pids[i];
  }
  free(pids);
  return found;
}

static int same_game(const md_game_t *a, const md_game_t *b) {
  return !strcmp(a->sha1, b->sha1) && !strcmp(a->host, b->host) && !strcmp(a->path, b->path);
}

static void add_game(md_game_t *out, int cap, int *n, const md_game_t *g) {
  for (int i = 0; i < *n; i++)
    if (same_game(&out[i], g) && !strcmp(out[i].name, g->name)) return;
  if (*n < cap) out[(*n)++] = *g;
}

// Decodes the statstring at p (at most avail bytes) into g's path, host and sha1.
static int parse_statstring(const unsigned char *p, size_t avail, md_game_t *g) {
  unsigned char dec[600];
  size_t dl = decode(p, avail < STAT_MAX ? avail : STAT_MAX, dec, sizeof dec - 1);
  dec[dl] = 0;
  unsigned char *m = memmem(dec, dl, "aps/", 4);
  if (!m || m == dec || (m[-1] != 'M' && m[-1] != 'm')) return 0;
  char *path = (char *)m - 1;
  size_t pl = strnlen(path, (size_t)(dec + dl - (unsigned char *)path));
  if (pl == 0 || pl >= sizeof g->path - 1) return 0;
  char *host = path + pl + 1;
  if ((unsigned char *)host >= dec + dl) return 0;
  size_t hl = strnlen(host, (size_t)(dec + dl - (unsigned char *)host));
  if (hl == 0 || hl >= sizeof g->host) return 0;
  unsigned char *sha = (unsigned char *)host + hl + 2;
  if (sha + 20 > dec + dl) return 0;
  snprintf(g->path, sizeof g->path, "%s", path);
  snprintf(g->host, sizeof g->host, "%.*s", (int)hl, host);
  for (int i = 0; i < 20; i++) snprintf(g->sha1 + 2 * i, 3, "%02x", sha[i]);
  return 1;
}

// Path A over one region.
static void scan_objects(const unsigned char *p, size_t n, md_game_t *out, int cap, int *count, scan_t *s) {
  for (size_t o = 32; o + 16 + STAT_MAX < n; o += 4) {
    if (!is_header(p, o)) continue;
    md_game_t g;
    memset(&g, 0, sizeof g);
    if (!parse_statstring(p + o + 16, STAT_MAX, &g)) continue;
    const char *name = (const char *)p + o - 32;
    snprintf(g.name, sizeof g.name, "%.*s", (int)strnlen(name, 32), name);
    g.source = MD_SOURCE_OBJECT;
    int before = *count;
    add_game(out, cap, count, &g);
    if (*count > before) s->st.objects++;
  }
}

// Path B over one region: statstrings that path A did not already take.
static void scan_statstrings(const unsigned char *p, size_t n, scan_t *s) {
  if (n < 32 + STAT_MAX) return;
  const unsigned char *end = p + n - STAT_MAX;
  for (const unsigned char *q = p + 17; q < end; q++) {
    q = memmem(q, (size_t)(end - q), "aqs/", 4);
    if (!q) break;
    const unsigned char *st = q - 17;
    if ((st[15] != 'M' && st[15] != 'm') || !(st[0] & 1) || !(st[8] & 1) || !(st[16] & 1)) continue;
    size_t off = (size_t)(st - p);
#ifndef MD_TEST_WITHOUT_OBJECTS
    if (off >= 48 && is_header(p, off - 16)) continue;  // an object - path A has it
#endif
    md_game_t g;
    memset(&g, 0, sizeof g);
    if (!parse_statstring(st, STAT_MAX, &g)) continue;
    g.source = MD_SOURCE_STATSTRING;
    int dup = 0;
    for (int i = 0; i < s->ncand && !dup; i++) dup = same_game(&s->cand[i], &g);
    if (!dup && s->ncand < MAX_CANDIDATES) s->cand[s->ncand++] = g;
  }
}

// Copies a JSON string body (after the opening quote) up to the closing quote; \" and \\ only.
static int json_string(const unsigned char *p, size_t max, char *out, size_t cap) {
  size_t i = 0, o = 0;
  while (i < max && p[i] != '"') {
    if (p[i] == '\\' && i + 1 < max) i++;
    if (o + 1 >= cap) return 0;
    out[o++] = (char)p[i++];
  }
  out[o] = 0;
  return i < max;
}

// Path C over one region: {"id":..,"name":"..",..,"mapFile":"..",..,"playerHost":".."}
static void scan_list(const unsigned char *p, size_t n, scan_t *s) {
  static const char KEY[] = "\"mapFile\":\"", HOST[] = "\"playerHost\":\"", NAME[] = "\"name\":\"";
  const unsigned char *end = p + n;
  for (const unsigned char *q = p; q < end; q++) {
    q = memmem(q, (size_t)(end - q), KEY, sizeof KEY - 1);
    if (!q) break;
    const unsigned char *v = q + sizeof KEY - 1;
    size_t lim = (size_t)(end - v) < 4096 ? (size_t)(end - v) : 4096;
    listed_t l;
    memset(&l, 0, sizeof l);
    if (!json_string(v, lim, l.path, sizeof l.path)) continue;
    const unsigned char *h = memmem(v, lim, HOST, sizeof HOST - 1);
    const unsigned char *next = memmem(v, lim, KEY, sizeof KEY - 1);
    if (!h || (next && next < h)) continue;
    if (!json_string(h + sizeof HOST - 1, (size_t)(end - h) - (sizeof HOST - 1), l.host, sizeof l.host)) continue;
    // The name comes first in the same object; look back no further than the previous entry.
    size_t back = (size_t)(q - p) < 512 ? (size_t)(q - p) : 512;
    const unsigned char *nm = NULL;
    for (const unsigned char *b = q - back; b < q; b++) {
      b = memmem(b, (size_t)(q - b), NAME, sizeof NAME - 1);
      if (!b) break;
      nm = b;
    }
    if (nm) {
      char name[200];
      if (json_string(nm + sizeof NAME - 1, (size_t)(q - nm), name, sizeof name))
        snprintf(l.name, sizeof l.name, "%s", name);
    }
    int dup = 0;
    for (int i = 0; i < s->nlisted && !dup; i++)
      dup = !strcmp(s->listed[i].host, l.host) && !strcmp(s->listed[i].path, l.path);
    if (!dup && s->nlisted < MAX_LISTED) s->listed[s->nlisted++] = l;
  }
}

int md_scan(pid_t pid, int full, md_game_t *out, int cap, int *kern_error, md_stats_t *stats) {
  if (stats) memset(stats, 0, sizeof *stats);
  mach_port_t task;
  kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
  if (kern_error) *kern_error = kr;
  if (kr != KERN_SUCCESS) return -1;
  scan_t s;
  memset(&s, 0, sizeof s);
  s.listed = calloc(MAX_LISTED, sizeof *s.listed);
  s.cand = calloc(MAX_CANDIDATES, sizeof *s.cand);
  if (!s.listed || !s.cand) {
    free(s.listed);
    free(s.cand);
    mach_port_deallocate(mach_task_self(), task);
    return -2;
  }
  int n = 0, rc = 0;
  mach_vm_address_t addr = 0;
  mach_vm_size_t size;
  natural_t depth = 0;
  while (1) {
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    kr = mach_vm_region_recurse(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt);
    if (kr != KERN_SUCCESS) {
      if (kr != KERN_INVALID_ADDRESS) { rc = -2; if (kern_error) *kern_error = kr; }
      break;
    }
    if (info.is_submap) { depth++; continue; }
    int fast = info.user_tag == 0 && info.protection == (VM_PROT_READ | VM_PROT_WRITE) && size <= FAST_MAX_REGION;
    int wanted = full ? ((info.protection & VM_PROT_READ) && size < (1ULL << 31)) : fast;
    if (wanted && info.pages_resident > 0) {
      vm_offset_t data;
      mach_msg_type_number_t dcnt;
      if (mach_vm_read(task, addr, size, &data, &dcnt) == KERN_SUCCESS) {
        const unsigned char *p = (const unsigned char *)data;
#ifndef MD_TEST_WITHOUT_OBJECTS  // test builds only: simulates a patch that breaks path A
        scan_objects(p, dcnt, out, cap, &n, &s);
#endif
        // Statstrings arrive from the network, so they live in writable memory; read-only
        // regions are mapped files and only cost time (a full scan went from 3.7 s to 12.9 s).
#ifndef MD_TEST_WITHOUT_STATSTRINGS  // test builds only: simulates a patch that breaks path B
        if (info.protection & VM_PROT_WRITE) scan_statstrings(p, dcnt, &s);
#endif
        // The list only confirms; reading it everywhere would add seconds to a full scan for copies
        // that, measured, all sit in the fast regions too.
        if (fast) scan_list(p, dcnt, &s);
        vm_deallocate(mach_task_self(), data, dcnt);
      }
    }
    addr += size;
  }
  mach_port_deallocate(mach_task_self(), task);
  // A statstring without an object counts only if the game's own list has that host and map.
  for (int i = 0; i < s.ncand; i++) {
    md_game_t *g = &s.cand[i];
    int known = 0;
    for (int k = 0; k < n && !known; k++) known = same_game(&out[k], g);
    if (known) continue;  // path A found it in a later region
    const listed_t *hit = NULL;
    for (int k = 0; k < s.nlisted && !hit; k++)
      if (!strcmp(s.listed[k].host, g->host) && !strcmp(s.listed[k].path, g->path)) hit = &s.listed[k];
    if (!hit) { s.st.unconfirmed++; continue; }
    snprintf(g->name, sizeof g->name, "%s", hit->name);
    int before = n;
    add_game(out, cap, &n, g);
    if (n > before) s.st.statstrings++;
  }
  s.st.listed = s.nlisted;
  if (stats) *stats = s.st;
  free(s.listed);
  free(s.cand);
  return rc ? rc : n;
}
