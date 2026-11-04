// MapDash game-list scanner: reads the Warcraft III custom game list out of the running game.
// Read-only by design - see scanner.c.
#ifndef MAPDASH_SCANNER_H
#define MAPDASH_SCANNER_H

#include <sys/types.h>

// How a lobby was found (md_game_t.source).
enum {
  MD_SOURCE_OBJECT = 1,      // the game's lobby object, recognised by its header
  MD_SOURCE_STATSTRING = 2,  // only the statstring itself, confirmed by the game's own lobby list
};

typedef struct {
  char name[33];   // lobby name
  char path[260];  // map path on the host's machine
  char host[64];   // host BattleTag
  char sha1[41];   // hex SHA-1 of the map file
  int source;      // MD_SOURCE_*
} md_game_t;

// What each detection path saw in one scan. Lets the app tell "the list is closed" from
// "the list is open and MapDash cannot read it", and shows which path carried the result.
typedef struct {
  int objects;      // lobbies found through the lobby object
  int statstrings;  // statstrings without a recognised object, confirmed by the lobby list
  int unconfirmed;  // statstrings without object and without a list entry (dropped, likely stale)
  int listed;       // distinct host+map entries in the game's own lobby list (JSON); no SHA-1
} md_stats_t;

// PID of the running game, 0 if none.
pid_t md_find_game(void);

// Scans the game once. full=0 reads only the small heap regions the objects were measured in,
// full=1 reads everything readable. Returns the number of games (<= cap) or a negative value:
//   -1  task_for_pid refused (kern_error holds the kern_return_t)
//   -2  the region walk failed (game probably exited)
// stats may be NULL.
int md_scan(pid_t pid, int full, md_game_t *out, int cap, int *kern_error, md_stats_t *stats);

#endif
