// MapDash game-list scanner: reads the Warcraft III custom game list out of the running game.
// Read-only by design - see scanner.c.
#ifndef MAPDASH_SCANNER_H
#define MAPDASH_SCANNER_H

#include <sys/types.h>

typedef struct {
  char name[33];   // lobby name
  char path[260];  // map path on the host's machine
  char host[64];   // host BattleTag
  char sha1[41];   // hex SHA-1 of the map file
} md_game_t;

// PID of the running game, 0 if none.
pid_t md_find_game(void);

// Scans the game once. full=0 reads only the small heap regions the objects were measured in,
// full=1 reads everything readable. Returns the number of games (<= cap) or a negative value:
//   -1  task_for_pid refused (kern_error holds the kern_return_t)
//   -2  the region walk failed (game probably exited)
int md_scan(pid_t pid, int full, md_game_t *out, int cap, int *kern_error);

#endif
