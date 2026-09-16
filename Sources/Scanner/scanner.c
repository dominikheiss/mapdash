// MapDash game-list scanner.
//
// Hard rule: the game process is only ever READ (task_for_pid + mach_vm_read). Never write to it,
// never suspend it, never attach a debugger - an lldb attach once dropped the Battle.net session.
//
// task_for_pid works without root because the game binary carries get-task-allow and macOS lets
// members of _developer (which nests the admin group by default) take such task ports.
//
// Layout of one lobby object (4-byte aligned):
//   +0  .. +31  lobby name, NUL terminated, 32-byte buffer
//   +32 .. +47  00000000 01000000 01000000 00000000
//   +48         W3 encoded statstring: 13 bytes flags/size/crc, map path NUL, host NUL, 0x00,
//               20-byte raw SHA-1 of the map file
// Freed objects of closed lobbies can linger, so a scan may include a few stale lobbies.
#include "scanner.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GAME_SUFFIX "/Warcraft III.app/Contents/MacOS/Warcraft III"
// Measured on an M4 (game under Rosetta): all 79 of 79 objects sat in untagged read-write
// regions of at most 0.3 MB. Scanning only those is ~4x cheaper; callers cross-check with a
// periodic full scan because this is an observation, not a guarantee.
#define FAST_MAX_REGION (4ULL << 20)

static const unsigned char HDR[16] = {0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0};

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
    if (pl >= sl && strcmp(path + pl - sl, GAME_SUFFIX) == 0) found = pids[i];
  }
  free(pids);
  return found;
}

static void add_game(md_game_t *out, int cap, int *n, const char *name, size_t nl, const char *path,
                     const char *host, size_t hl, const unsigned char *sha) {
  if (*n >= cap) return;
  md_game_t g;
  memset(&g, 0, sizeof g);
  snprintf(g.name, sizeof g.name, "%.*s", (int)nl, name);
  snprintf(g.path, sizeof g.path, "%s", path);
  snprintf(g.host, sizeof g.host, "%.*s", (int)hl, host);
  for (int i = 0; i < 20; i++) snprintf(g.sha1 + 2 * i, 3, "%02x", sha[i]);
  for (int i = 0; i < *n; i++)
    if (!strcmp(out[i].sha1, g.sha1) && !strcmp(out[i].name, g.name) && !strcmp(out[i].host, g.host)) return;
  out[(*n)++] = g;
}

int md_scan(pid_t pid, int full, md_game_t *out, int cap, int *kern_error) {
  mach_port_t task;
  kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
  if (kern_error) *kern_error = kr;
  if (kr != KERN_SUCCESS) return -1;
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
    int wanted = full ? ((info.protection & VM_PROT_READ) && size < (1ULL << 31))
                      : (info.user_tag == 0 && info.protection == (VM_PROT_READ | VM_PROT_WRITE) &&
                         size <= FAST_MAX_REGION);
    if (wanted && info.pages_resident > 0) {
      vm_offset_t data;
      mach_msg_type_number_t dcnt;
      if (mach_vm_read(task, addr, size, &data, &dcnt) == KERN_SUCCESS) {
        unsigned char *p = (unsigned char *)data;
        for (size_t o = 32; o + 16 + 512 < dcnt; o += 4) {
          if (memcmp(p + o, HDR, 16) != 0) continue;
          unsigned char dec[600];
          size_t dl = decode(p + o + 16, 512, dec, sizeof dec - 1);
          dec[dl] = 0;
          unsigned char *m = memmem(dec, dl, "aps/", 4);
          if (!m || m == dec || (m[-1] != 'M' && m[-1] != 'm')) continue;
          char *path = (char *)m - 1;
          size_t pl = strnlen(path, (size_t)(dec + dl - (unsigned char *)path));
          if (pl == 0 || pl >= 259) continue;
          char *host = path + pl + 1;
          if ((unsigned char *)host >= dec + dl) continue;
          size_t hl = strnlen(host, (size_t)(dec + dl - (unsigned char *)host));
          unsigned char *sha = (unsigned char *)host + hl + 2;
          if (sha + 20 > dec + dl) continue;
          const char *name = (const char *)p + o - 32;
          add_game(out, cap, &n, name, strnlen(name, 32), path, host, hl, sha);
        }
        vm_deallocate(mach_task_self(), data, dcnt);
      }
    }
    addr += size;
  }
  mach_port_deallocate(mach_task_self(), task);
  return rc ? rc : n;
}
