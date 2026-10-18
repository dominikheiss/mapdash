// V27: Read-only, narrowly scoped Warcraft process memory scan for CDN map URLs.
// Reports *only* map-content SHA-1 candidates embedded in exact CDN path shapes.
// Does not read or write user map files, alter game process memory, or perform network I/O.
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
#define TAIL 160u
#define MAX_HASHES 64u
#define BUDGET (UINT64_C(2)*1024*1024*1024)
static const char *marker = "W3-maps-user/";
static const char *suffix = ".map";
typedef struct {char sha1[41]; unsigned sightings; unsigned encoding;} Candidate;
typedef struct {Candidate hits[MAX_HASHES]; unsigned used, overflow; uint64_t scanned;} Detector;

static int hexdigit(unsigned char c) {
  if (c >= '0' && c <= '9') return c-'0';
  if (c >= 'a' && c <= 'f') return c-'a'+10;
  if (c >= 'A' && c <= 'F') return c-'A'+10;
  return -1;
}
static void record(Detector *d,const char *hash,unsigned encoding) {
  for (unsigned i=0;i<d->used;i++) if (!memcmp(d->hits[i].sha1,hash,40)) {
    d->hits[i].sightings++; d->hits[i].encoding |= encoding;return;
  }
  if (d->used==MAX_HASHES) {d->overflow++;return;}
  Candidate *c=&d->hits[d->used++];
  memcpy(c->sha1,hash,41);c->sightings=1;c->encoding=encoding;
}
static int matches(const unsigned char *buf,size_t n,size_t i,const char *word,int stride) {
  size_t m=strlen(word);
  if (m > (n-i)/(size_t)stride) return 0;
  for(size_t j=0;j<m;j++) {
    if (buf[i+j*(size_t)stride] != (unsigned char)word[j]) return 0;
    if(stride==2 && buf[i+j*2+1] != 0) return 0;
  }
  return 1;
}
static void scan_bytes(Detector *d,const unsigned char *buf,size_t n) {
  const size_t m=strlen(marker);
  // We only identify values in explicit CDN object paths, not arbitrary SHA-1 strings.
  for(size_t i=0;i<n;i++) {
    if(buf[i]!='W') continue;
    for(int stride=1;stride<=2;stride++) {
      size_t need=(m+40+4)*(size_t)stride;
      if(need>n-i || !matches(buf,n,i,marker,stride))continue;
      char hash[41];int ok=1;
      for(size_t j=0;j<40;j++) {
        size_t pos=i+(m+j)*(size_t)stride;
        int h=hexdigit(buf[pos]);
        if(h<0 || (stride==2 && buf[pos+1]!=0)) {ok=0;break;}
        hash[j]="0123456789abcdef"[h];
      }
      if(!ok)continue;
      hash[40]=0;
      if(!matches(buf,n,i+(m+40)*(size_t)stride,suffix,stride))continue;
      record(d,hash,(unsigned)stride);
    }
  }
}
static void feed(Detector *d,const unsigned char *buf,size_t n,unsigned char tail[TAIL],size_t *tail_n) {
  unsigned char *joined=malloc(*tail_n+n);
  if(!joined)return;
  memcpy(joined,tail,*tail_n);memcpy(joined+*tail_n,buf,n);
  size_t total=*tail_n+n;
  scan_bytes(d,joined,total);
  *tail_n=total<TAIL?total:TAIL;
  memcpy(tail,joined+total-*tail_n,*tail_n);
  free(joined);
}
static int output(const Detector *d) {
  printf("v27_memory scanned_mib=%llu distinct_cdn_sha1=%u overflow=%u\n",
    (unsigned long long)(d->scanned>>20),d->used,d->overflow);
  for(unsigned i=0;i<d->used;i++)
    printf("v27_candidate sha1=%s sightings=%u encoding=%s\n",d->hits[i].sha1,
      d->hits[i].sightings,d->hits[i].encoding==1?"ascii":d->hits[i].encoding==2?"utf16le":"ascii+utf16le");
  return d->overflow?3:0;
}
static int scan_file(const char *path) {
  FILE *f=fopen(path,"rb");if(!f){fputs("v27_error fixture_unreadable\n",stderr);return 2;}
  Detector d={0};unsigned char *buf=malloc(CHUNK);if(!buf){fclose(f);return 2;}
  unsigned char tail[TAIL]={0};size_t tail_n=0,n;
  while((n=fread(buf,1,CHUNK,f))>0){feed(&d,buf,n,tail,&tail_n);d.scanned+=n;}
  int error=ferror(f);fclose(f);free(buf);if(error)return 2;
  return output(&d);
}
#ifdef __APPLE__
static int scan_game(int pid) {
  mach_port_t task=0;
  kern_return_t kr=task_for_pid(mach_task_self(),pid,&task);
  if(kr!=KERN_SUCCESS){fprintf(stderr,"v27_error task_for_pid_denied code=%d\n",kr);return 2;}
  Detector d={0};unsigned char *buf=malloc(CHUNK);
  if(!buf){mach_port_deallocate(mach_task_self(),task);return 2;}
  unsigned char tail[TAIL]={0};size_t tail_n=0;
  mach_vm_address_t addr=0;mach_vm_size_t size=0;natural_t depth=0;
  uint64_t regions=0;
  while(d.scanned<BUDGET) {
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_SUBMAP_INFO_COUNT_64;
    kr=mach_vm_region_recurse(task,&addr,&size,&depth,(vm_region_recurse_info_t)&info,&count);
    if(kr!=KERN_SUCCESS)break;
    if(info.is_submap){depth++;continue;}
    if((info.protection & VM_PROT_READ) && info.pages_resident>0 && size){
      regions++;mach_vm_size_t off=0;
      while(off<size && d.scanned<BUDGET){
        mach_vm_size_t amount=size-off<CHUNK?size-off:CHUNK;
        if(amount>BUDGET-d.scanned)amount=BUDGET-d.scanned;
        mach_vm_size_t got=0;
        kern_return_t r=mach_vm_read_overwrite(task,addr+off,amount,(mach_vm_address_t)(uintptr_t)buf,&got);
        d.scanned+=amount;
        if(r==KERN_SUCCESS && got)feed(&d,buf,(size_t)got,tail,&tail_n);
        else tail_n=0;
        off+=amount;
      }
      tail_n=0;
    }
    if(UINT64_MAX-addr<size)break;addr+=size;
  }
  fprintf(stderr,"v27_regions=%llu read_only=1\n",(unsigned long long)regions);
  free(buf);mach_port_deallocate(mach_task_self(),task);
  return output(&d);
}
#endif
int main(int argc,char **argv){
  if(argc==3 && !strcmp(argv[1],"--fixture"))return scan_file(argv[2]);
#ifdef __APPLE__
  if(argc==2){char *end=NULL;errno=0;long pid=strtol(argv[1],&end,10);
    if(!errno && end && !*end && pid>0 && pid<=INT32_MAX)return scan_game((int)pid);}
#endif
  fputs("v27_error usage_invalid (expected pid or --fixture path)\n",stderr);
  return 2;
}
