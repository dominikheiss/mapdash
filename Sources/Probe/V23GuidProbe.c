// V23: read-only search for numeric WebUI session identifiers inside Warcraft III.
// Standard output contains only candidate IDs and MUST be piped directly to the local
// WebSocket probe, never logged. No process writes or debugging/ptrace attachment.
#define _DARWIN_C_SOURCE 1
#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

#define CHUNK (1u << 20)
#define TAIL 128u
#define CAND_MAX 16u
#define DIGIT_MAX 32u

struct candidate { char id[DIGIT_MAX + 1u]; unsigned count; };
struct detector { struct candidate ids[CAND_MAX]; unsigned used, occurrences, dropped; };

static void scan_bytes(struct detector *d, const unsigned char *p, size_t n) {
  static const char *patterns[] = { "?guid=", "webui-socket/" };
  for (size_t i = 0; i < n; i++) {
    if (p[i] != '?' && p[i] != 'w') continue;
    for (unsigned k = 0; k < 2; k++) {
      size_t sl = strlen(patterns[k]);
      if (i + sl + 11u > n || memcmp(p+i, patterns[k], sl)) continue;
      size_t start = i + sl, end = start;
      while (end < n && p[end] >= '0' && p[end] <= '9' && end - start <= DIGIT_MAX) end++;
      // Reject truncated strings, giant numbers, and neighboring text with longer digits.
      if (end == n || end - start < 11u || end - start > DIGIT_MAX ||
          (p[end] >= '0' && p[end] <= '9')) continue;
      d->occurrences++;
      unsigned j = 0;
      for (; j < d->used; j++)
        if (strlen(d->ids[j].id) == end-start && !memcmp(d->ids[j].id, p+start, end-start)) break;
      if (j < d->used) { d->ids[j].count++; continue; }
      if (d->used >= CAND_MAX) { d->dropped++; continue; }
      memcpy(d->ids[j].id, p+start, end-start);
      d->ids[j].id[end-start] = '\0';
      d->ids[j].count = 1;
      d->used++;
    }
  }
}

static void feed(struct detector *d, const unsigned char *chunk, size_t len,
                 unsigned char tail[TAIL], size_t *tail_n) {
  // Overlap regions/chunks so a marker straddling the boundary can still match.
  unsigned char *joined = malloc(*tail_n + len);
  if (!joined) return;
  memcpy(joined, tail, *tail_n);
  memcpy(joined + *tail_n, chunk, len);
  size_t total = *tail_n + len;
  scan_bytes(d, joined, total);
  *tail_n = total < TAIL ? total : TAIL;
  memcpy(tail, joined+total-*tail_n, *tail_n);
  free(joined);
}

static int output(const struct detector *d) {
  fprintf(stderr, "v23_guid_scan candidates=%u occurrences=%u overflow=%u (identifiers withheld)\n",
          d->used, d->occurrences, d->dropped);
  if (!d->used || d->dropped) return 1;
  // Try up to 16 unique IDs locally. Only protocol handshake confirms validity.
  for (unsigned i = 0; i < d->used; i++) puts(d->ids[i].id);
  return 0;
}

static int scan_fixture(const char *filename) {
  FILE *f = fopen(filename, "rb");
  if (!f) { fprintf(stderr, "v23_error fixture_unreadable\n"); return 2; }
  struct detector d = {0};
  unsigned char *buf = malloc(CHUNK);
  if (!buf) { fclose(f); return 2; }
  unsigned char tail[TAIL] = {0}; size_t tail_n = 0;
  size_t n;
  while ((n = fread(buf,1,CHUNK,f)) != 0) feed(&d,buf,n,tail,&tail_n);
  int err = ferror(f);
  free(buf); fclose(f);
  if (err) return 2;
  return output(&d);
}

#ifdef __APPLE__
static int scan_game(int pid) {
  mach_port_t task;
  kern_return_t kr = task_for_pid(mach_task_self(),pid,&task);
  if (kr != KERN_SUCCESS) {
    fprintf(stderr,"v23_error task_for_pid_denied code=%d\n",kr);
    return 2;
  }
  unsigned char *buf = malloc(CHUNK);
  if (!buf) { mach_port_deallocate(mach_task_self(),task); return 2; }
  struct detector d = {0};
  unsigned char tail[TAIL] = {0}; size_t tail_n=0;
  mach_vm_address_t addr=0; mach_vm_size_t size=0;
  natural_t depth=0;
  uint64_t examined=0, regions=0;
  const uint64_t budget=UINT64_C(2)*1024*1024*1024;
  while (examined < budget) {
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_SUBMAP_INFO_COUNT_64;
    kr = mach_vm_region_recurse(task,&addr,&size,&depth,(vm_region_recurse_info_t)&info,&count);
    if (kr != KERN_SUCCESS) break;
    if (info.is_submap) { depth++; continue; }
    if ((info.protection & VM_PROT_READ) && info.pages_resident > 0 && size) {
      regions++;
      mach_vm_size_t off=0;
      while (off < size && examined < budget) {
        mach_vm_size_t amount=size-off < CHUNK ? size-off : CHUNK;
        if (amount > budget-examined) amount=budget-examined;
        mach_vm_size_t got=0;
        kern_return_t r=mach_vm_read_overwrite(task,addr+off,amount,(mach_vm_address_t)(uintptr_t)buf,&got);
        examined += amount;
        if (r == KERN_SUCCESS && got) feed(&d,buf,(size_t)got,tail,&tail_n);
        else tail_n=0;
        off += amount;
      }
      // Memory from distinct regions is not logically contiguous.
      tail_n=0;
    }
    if (UINT64_MAX - addr < size) break;
    addr += size;
  }
  free(buf);
  mach_port_deallocate(mach_task_self(),task);
  fprintf(stderr,"v23_memory regions=%llu scanned_mib=%llu budget_mib=2048\n",
          (unsigned long long)regions,(unsigned long long)(examined >> 20));
  return output(&d);
}
#endif

int main(int argc,char **argv) {
  if (argc == 3 && !strcmp(argv[1],"--fixture")) return scan_fixture(argv[2]);
#ifdef __APPLE__
  if (argc == 2) {
    char *end=NULL; errno=0;
    long v=strtol(argv[1],&end,10);
    if (!errno && end && !*end && v>0 && v<=INT32_MAX) return scan_game((int)v);
  }
#else
  (void)argv;
#endif
  fprintf(stderr,"v23_error usage_invalid (requires pid or --fixture path)\n");
  return 2;
}
