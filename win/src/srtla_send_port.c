#ifndef VERSION
#define VERSION "nts-air-win"
#endif
/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2020-2021 BELABOX project

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

/* nTs-AIR: port portabil Windows (Winsock) + Linux.
   Modificari fata de upstream (github.com/BELABOX/srtla):
   - Winsock, SIO_UDP_CONNRESET dezactivat, socket non-blocking via ioctlsocket
   - reincarcarea listei de IP-uri: fisierul e verificat la fiecare secunda
     (pe Windows nu exista SIGHUP; pe Linux SIGHUP functioneaza in continuare)
   - getline / urandom / clock_gettime inlocuite cu echivalente portabile */
#ifdef _WIN32
  #define _CRT_RAND_S
  #define FD_SETSIZE 256
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #include <windows.h>
  #include <mstcpip.h>
  typedef SOCKET sock_t;
  #define BAD_SOCK INVALID_SOCKET
  #define close_sock closesocket
  #ifndef SIO_UDP_CONNRESET
  #define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
  #endif
#else
  #include <unistd.h>
  #include <signal.h>
  #include <netdb.h>
  #include <fcntl.h>
  #include <sys/types.h>
  #include <sys/socket.h>
  #include <sys/select.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  typedef int sock_t;
  #define BAD_SOCK (-1)
  #define close_sock close
#endif
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#define be16toh_(x) ntohs(x)
#define htobe16_(x) htons(x)
#define be32toh_(x) ntohl(x)

#define MTU 1500

#define SRT_TYPE_HANDSHAKE   0x8000
#define SRT_TYPE_ACK         0x8002
#define SRT_TYPE_NAK         0x8003
#define SRT_TYPE_SHUTDOWN    0x8005

#define SRTLA_TYPE_KEEPALIVE 0x9000
#define SRTLA_TYPE_ACK       0x9100
#define SRTLA_TYPE_REG1      0x9200
#define SRTLA_TYPE_REG2      0x9201
#define SRTLA_TYPE_REG3      0x9202
#define SRTLA_TYPE_REG_ERR   0x9210
#define SRTLA_TYPE_REG_NGP   0x9211
#define SRTLA_TYPE_REG_NAK   0x9212

#define SRT_MIN_LEN          16

#define SRTLA_ID_LEN         256
#define SRTLA_TYPE_REG1_LEN  (2 + (SRTLA_ID_LEN))
#define SRTLA_TYPE_REG2_LEN  (2 + (SRTLA_ID_LEN))
#define SRTLA_TYPE_REG3_LEN  2

#define LOG_NONE    0   // prints only fatal errors
#define LOG_ERR     1   // prints errors we can tolerate
#define LOG_INFO    2   // prints informational messages
#define LOG_DEBUG   3   // prints potentially verbose messages about the internal workings

#define LOG_LEVEL LOG_INFO

#if LOG_LEVEL >= LOG_DEBUG
  #define debug(...) fprintf(stderr, __VA_ARGS__)
#else
  #define debug(...)
#endif

#if LOG_LEVEL >= LOG_INFO
  #define info(...) fprintf(stderr, __VA_ARGS__)
#else
  #define info(...)
#endif

#if LOG_LEVEL >= LOG_ERR
  #define err(...) fprintf(stderr, __VA_ARGS__)
#else
  #define err(...)
#endif


void print_help();
void exit_help();

static uint64_t mono_ms(void) {
#ifdef _WIN32
  return (uint64_t)GetTickCount64();
#else
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static void set_nonblock(sock_t fd) {
#ifdef _WIN32
  u_long m = 1; ioctlsocket(fd, FIONBIO, &m);
  BOOL f = FALSE; DWORD r = 0;
  WSAIoctl(fd, SIO_UDP_CONNRESET, &f, sizeof(f), NULL, 0, &r, NULL, NULL);
#else
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
#endif
}

static void random_bytes(char *buf, int n) {
#ifdef _WIN32
  for (int i = 0; i < n; i += 4) {
    unsigned int r; rand_s(&r);
    memcpy(buf + i, &r, (n - i) < 4 ? (n - i) : 4);
  }
#else
  FILE *f = fopen("/dev/urandom", "rb");
  assert(f != NULL);
  assert(fread(buf, 1, n, f) == (size_t)n);
  fclose(f);
#endif
}

/* citeste tot fisierul (max 64KB); 0 = ok */
static int read_whole(const char *fn, char *buf, size_t sz) {
  FILE *f = fopen(fn, "rb");
  if (!f) return -1;
  size_t n = fread(buf, 1, sz - 1, f);
  buf[n] = 0; fclose(f);
  return 0;
}
void exit_help() {
  print_help();
  exit(EXIT_FAILURE);
}

#define ADDR_BUF_SZ 50
char _global_addr_buf[ADDR_BUF_SZ];
const char *print_addr(struct sockaddr *addr) {
  struct sockaddr_in *ain = (struct sockaddr_in *)addr;
  return inet_ntop(ain->sin_family, &ain->sin_addr, _global_addr_buf, ADDR_BUF_SZ);
}

int port_no(struct sockaddr *addr) {
  struct sockaddr_in *ain = (struct sockaddr_in *)addr;
  return ntohs(ain->sin_port);
}

int parse_ip(struct sockaddr_in *addr, char *ip_str) {
  while (*ip_str == ' ' || *ip_str == '\t') ip_str++;
  char *e = ip_str + strlen(ip_str);
  while (e > ip_str && (e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
  if (!*ip_str) return -1;
  unsigned long ip = inet_addr(ip_str);
  if (ip == INADDR_NONE) return -1;

  memset(addr, 0, sizeof(*addr));
  addr->sin_family = AF_INET;
  addr->sin_addr.s_addr = ip;

  return 0;
}

int parse_port(char *port_str) {
  int port = strtol(port_str, NULL, 10);
  if (port <= 0 || port > 65535) return -2;
  return port;
}

int get_seconds(time_t *s) { *s = (time_t)(mono_ms() / 1000); return 0; }
int get_ms(uint64_t *ms) { *ms = mono_ms(); return 0; }

int32_t get_srt_sn(void *pkt, int n) {
  if (n < 4) return -1;

  uint32_t sn = be32toh_(*((uint32_t *)pkt));
  if ((sn & (1 << 31)) == 0) {
    return (int32_t)sn;
  }

  return -1;
}

uint16_t get_srt_type(void *pkt, int n) {
  if (n < 2) return 0;
  return be16toh_(*((uint16_t *)pkt));
}

int is_srt_ack(void *pkt, int n) {
  return get_srt_type(pkt, n) == SRT_TYPE_ACK;
}

int is_srtla_keepalive(void *pkt, int n) {
  return get_srt_type(pkt, n) == SRTLA_TYPE_KEEPALIVE;
}

int is_srtla_reg1(void *pkt, int len) {
  if (len != SRTLA_TYPE_REG1_LEN) return 0;
  return get_srt_type(pkt, len) == SRTLA_TYPE_REG1;
}

int is_srtla_reg2(void *pkt, int len) {
  if (len != SRTLA_TYPE_REG2_LEN) return 0;
  return get_srt_type(pkt, len) == SRTLA_TYPE_REG2;
}

int is_srtla_reg3(void *pkt, int len) {
  if (len != SRTLA_TYPE_REG3_LEN) return 0;
  return get_srt_type(pkt, len) == SRTLA_TYPE_REG3;
}
#define PKT_LOG_SZ 256
#define CONN_TIMEOUT 4
#define REG2_TIMEOUT 4
#define REG3_TIMEOUT 4
#define GLOBAL_TIMEOUT 10
#define IDLE_TIME 1

#define SEND_BUF_SIZE (8 * 1024 * 1024)

#undef min
#undef max
#define min(a, b) ((a < b) ? a : b)
#define max(a, b) ((a > b) ? a : b)
#define min_max(a, l, h) (max(min((a), (h)), (l)))

#define WINDOW_MIN 1
#define WINDOW_DEF 20
#define WINDOW_MAX 60
#define WINDOW_MULT 1000
#define WINDOW_DECR 100
#define WINDOW_INCR 30

#define LOG_PKT_INT 20

typedef struct conn {
  struct conn *next;
  sock_t fd;
  time_t last_rcvd;
  time_t last_sent;
  struct sockaddr src;
  int removed;
  int in_flight_pkts;
  int window;
  int pkt_idx;
  int pkt_log[PKT_LOG_SZ];
} conn_t;

char *source_ip_file = NULL;

int do_update_conns = 0;

struct addrinfo *addrs;

struct sockaddr srtla_addr, srt_addr;
const socklen_t addr_len = sizeof(srtla_addr);
conn_t *conns = NULL;
sock_t listenfd;
int active_connections = 0;
int has_connected = 0;

conn_t *pending_reg2_conn = NULL;
time_t pending_reg_timeout = 0;

char srtla_id[SRTLA_ID_LEN];


/*

Async I/O support

*/
fd_set active_fds;
int add_active_fd(sock_t fd) {
  if (fd == BAD_SOCK) return -1;

  FD_SET(fd, &active_fds);

  return 0;
}

int remove_active_fd(sock_t fd) {
  if (fd == BAD_SOCK) return -1;

  FD_CLR(fd, &active_fds);

  return 0;
}


/*

Misc helper functions

*/
void print_help() {
  fprintf(stderr,
          "Syntax: srtla_send SRT_LISTEN_PORT SRTLA_HOST SRTLA_PORT BIND_IPS_FILE\n\n"
          "-v      Print the version and exit\n");
}


/*

srtla registration helpers

*/
int send_reg1(conn_t *c) {
  if (c->fd == BAD_SOCK) return -1;

  char buf[MTU];
  uint16_t packet_type = htobe16_(SRTLA_TYPE_REG1);
  memcpy(buf, &packet_type, sizeof(packet_type));
  memcpy(buf + sizeof(packet_type), srtla_id, SRTLA_ID_LEN);

  int ret = sendto(c->fd, (const char *)buf, SRTLA_TYPE_REG1_LEN, 0, &srtla_addr, addr_len);
  if (ret != SRTLA_TYPE_REG1_LEN) return -1;

  return 0;
}

int send_reg2(conn_t *c) {
  if (c->fd == BAD_SOCK) return -1;

  char buf[SRTLA_TYPE_REG2_LEN];
  uint16_t packet_type = htobe16_(SRTLA_TYPE_REG2);
  memcpy(buf, &packet_type, sizeof(packet_type));
  memcpy(buf + sizeof(packet_type), srtla_id, SRTLA_ID_LEN);

  int ret = sendto(c->fd, (const char *)buf, SRTLA_TYPE_REG2_LEN, 0, &srtla_addr, addr_len);
  return (ret == SRTLA_TYPE_REG2_LEN) ? 0 : -1;
}


/*

Handling code for packets coming from the SRT caller

*/
void reg_pkt(conn_t *c, int32_t packet) {
  debug("%s (%p): register packet %d at idx %d\n",
        print_addr(&c->src), c, packet, c->pkt_idx);
  c->pkt_log[c->pkt_idx] = packet;
  c->pkt_idx++;
  c->pkt_idx %= PKT_LOG_SZ;

  c->in_flight_pkts++;
}

int conn_timed_out(conn_t *c, time_t ts) {
  return (c->last_rcvd + CONN_TIMEOUT) < ts;
}

conn_t *select_conn() {
  conn_t *min_c = NULL;
  int max_score = -1;
  int max_window = 0;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->window > max_window) {
      max_window = c->window;
    }
  }

  time_t t;
  assert(get_seconds(&t) == 0);

  for (conn_t *c = conns; c != NULL; c = c->next) {
    /* If we have some very slow links, we may be better off ignoring them
       However, we'd probably need to periodically re-probe them, otherwise
       a link disabled due to a momentary glitch might not ever get enabled
       again unless all the remaining links suffered from high packet loss
       at some point. */
    /*if (c->window < max_window / 5) {
      c->window++;
      continue;
    }*/

    if (conn_timed_out(c, t)) {
      debug("%s (%p): is timed out, ignoring it\n", print_addr(&c->src), c);
      continue;
    }

    int score = c->window / (c->in_flight_pkts + 1);
    if (score > max_score) {
      min_c = c;
      max_score = score;
    }
  }

  if (min_c) {
    min_c->last_sent = t;
  }

  return min_c;
}

void handle_srt_data(sock_t fd) {
  char buf[MTU];
  socklen_t len = sizeof(srt_addr);
  int n = recvfrom(fd, buf, MTU, 0, &srt_addr, &len);
  if (n <= 0) return;

  conn_t *c = select_conn();
  if (c) {
    int32_t sn = get_srt_sn(buf, n);
    int ret = sendto(c->fd, buf, n, 0, &srtla_addr, addr_len);
    if (ret == n) {
      if (sn >= 0) {
        reg_pkt(c, sn);
      }
    } else {
      /* If sending the packet fails, adjust the timestamp to disable the link until a
         reconnection is confirmed. 1 so connection_housekeeping() prints its message */
      c->last_rcvd = 1;
      err("%s (%p): sendto() failed, disabling the connection\n",
          print_addr(&c->src), c);
    }
  }
}


/*

Handling code for packets coming from the receiver

*/
int get_pkt_idx(int idx, int increment) {
  idx = idx + increment;
  if (idx < 0) idx += PKT_LOG_SZ;
  idx %= PKT_LOG_SZ;
  assert(idx >= 0 && idx < PKT_LOG_SZ);
  return idx;
}

void register_nak(int32_t packet) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    int idx = get_pkt_idx(c->pkt_idx, -1);
    for (int i = idx; i != c->pkt_idx; i = get_pkt_idx(i, -1)) {
      if (c->pkt_log[i] == packet) {
        c->pkt_log[i] = -1;
        // It might be better to use exponential decay like this
        //c->window = c->window * 998 / 1000;
        c->window -= WINDOW_DECR;
        c->window = max(c->window, WINDOW_MIN*WINDOW_MULT);
        debug("%s (%p): found NAKed packet %d in the log\n",
              print_addr(&c->src), c, packet);
        return;
      }
    }
  }

  debug("Didn't find NAKed packet %d in our logs\n", packet);
}

void register_srtla_ack(int32_t ack) {
  int found = 0;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    int idx = get_pkt_idx(c->pkt_idx, -1);
    for (int i = idx; i != c->pkt_idx && !found; i = get_pkt_idx(i, -1)) {
      if (c->pkt_log[i] == ack) {
        found = 1;
        if (c->in_flight_pkts > 0) {
          c->in_flight_pkts--;
        }
        c->pkt_log[i] = -1;

        if (c->in_flight_pkts*WINDOW_MULT > c->window) {
          c->window += WINDOW_INCR - 1;
        }

        break;
      }
    }

    if (c->last_rcvd != 0) {
      c->window += 1;
      c->window = min(c->window, WINDOW_MAX*WINDOW_MULT);
    }
  }
}

/*
  TODO after the sequence number overflows, we should probably also mark high
  sn packets as received. However, this shouldn't normally be an issue as SRTLA
  ACKs acknowledge each packet individually. Also, if the SRTLA ACK is lost,
  stale entries will be overwritten soon enough as pkt_log is a circular buffer
*/
void conn_register_srt_ack(conn_t *c, int32_t ack) {
  int count = 0;
  int idx = get_pkt_idx(c->pkt_idx, -1);
  for (int i = idx; i != c->pkt_idx; i = get_pkt_idx(i, -1)) {
    if (c->pkt_log[i] < ack) {
      c->pkt_log[i] = -1;
    } else {
      count++;
    }
  }
  c->in_flight_pkts = count;
}

void register_srt_ack(int32_t ack) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    conn_register_srt_ack(c, ack);
  }
}

void handle_srtla_data(conn_t *c) {
  char buf[MTU];

  int n = recvfrom(c->fd, buf, MTU, 0, NULL, NULL);
  if (n <= 0) return;

  time_t ts;
  get_seconds(&ts);

  uint16_t packet_type = get_srt_type(buf, n);

  /* Handling NGPs separately because we don't want them to update last_rcvd
     Otherwise they could be keeping failed connections marked active */
  if (packet_type == SRTLA_TYPE_REG_NGP) {
    /* Only process NGPs if:
       * we don't have any established connections
       * and we don't already have a pending REG1->REG2 exhange in flight
       * and we don't have any pending REG2->REG3 exchanges in flight
    */
    if (active_connections == 0 && pending_reg2_conn == NULL && ts > pending_reg_timeout) {
      if (send_reg1(c) == 0) {
        pending_reg2_conn = c;
        pending_reg_timeout = ts + REG2_TIMEOUT;
      }
    }
    return;

  } else if (packet_type == SRTLA_TYPE_REG2) {
    if (pending_reg2_conn == c) {
      char *id = &buf[2];
      if (memcmp(id, srtla_id, SRTLA_ID_LEN/2) != 0) {
        err("%s (%p): got a mismatching ID in SRTLA_REG2\n",
           print_addr(&c->src), c);
        return;
      }

      info("%s (%p): connection group registered\n", print_addr(&c->src), c);
      memcpy(srtla_id, id, SRTLA_ID_LEN);

      /* Broadcast REG2 */
      for (conn_t *i = conns; i != NULL; i = i->next) {
        send_reg2(i);
      }

      pending_reg2_conn = NULL;
      pending_reg_timeout = ts + REG3_TIMEOUT;
    }
    return;
  }

  c->last_rcvd = ts;

  switch(packet_type) {
    case SRT_TYPE_ACK: {
      uint32_t last_ack = *((uint32_t *)&buf[16]);
      last_ack = be32toh_(last_ack);
      register_srt_ack(last_ack);
      break;
    }

    case SRT_TYPE_NAK: {
      uint32_t *ids = (uint32_t *)buf;
      for (int i = 4; i < n/4; i++) {
        uint32_t id = be32toh_(ids[i]);
        if (id & (1 << 31)) {
          id = id & 0x7FFFFFFF;
          uint32_t last_id = be32toh_(ids[i+1]);
          for (int32_t lost = id; lost <= last_id; lost++) {
            register_nak(lost);
          }
          i++;
        } else {
          register_nak(id);
        }
      }
      break;
    }

    // srtla packets below, don't send to SRT
    case SRTLA_TYPE_ACK: {
      uint32_t *acks = (uint32_t *)buf;
      for (int i = 1; i < n/4; i++) {
        uint32_t id = be32toh_(acks[i]);
        debug("%s (%p): ack %d\n", print_addr(&c->src), c, id);
        register_srtla_ack(id);
      }
      return;
    }
    case SRTLA_TYPE_KEEPALIVE:
      debug("%s (%p): got a keepalive\n", print_addr(&c->src), c);
      return; // don't send to SRT

    case SRTLA_TYPE_REG3:
      has_connected = 1;
      active_connections++;
      info("%s (%p): connection established\n", print_addr(&c->src), c);
      return;
  } // switch

  sendto(listenfd, buf, n, 0, &srt_addr, addr_len);
}


/*

Connection and socket management

*/
conn_t *conn_find_by_src(struct sockaddr *src) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (memcmp(src, &c->src, sizeof(*src)) == 0) {
      return c;
    }
  }

  return NULL;
}

int setup_conns(char *source_ip_file) {
  FILE *config = fopen(source_ip_file, "r");
  if (config == NULL) {
    perror("Failed to open the source ip list file: ");
    exit_help();
  }

  int count = 0;
  char line[256];
  while (fgets(line, sizeof(line), config)) {
    char *nl;
    if ((nl = strchr(line, '\n'))) {
      *nl = '\0';
    }

    struct sockaddr src;
    memset(&src, 0, sizeof(src));

    int ret = parse_ip((struct sockaddr_in *)&src, line);
    if (ret == 0) {
      conn_t *c = conn_find_by_src(&src);
      if (c == NULL) {
        conn_t *c = calloc(1, sizeof(conn_t));
        assert(c != NULL);

        c->src = src;
        c->fd = BAD_SOCK;
        c->window = WINDOW_DEF * WINDOW_MULT;

        c->next = conns;
        conns = c;

        count++;

        printf("Added connection via %s (%p)\n", print_addr(&c->src), c);
        fflush(stdout);
      } else {
        c->removed = 0;
      }
    }
  }

  fclose(config);

  return count;
}

void update_conns(char *source_ip_file) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    c->removed = 1;
  }

  setup_conns(source_ip_file);

  conn_t **prev = &conns;
  conn_t *next;
  for (conn_t *c = conns; c != NULL; c = next) {
    next = c->next;
    if (c->removed) {
      printf("Removed connection via %s (%p)\n", print_addr(&c->src), c);
      fflush(stdout);

      if (c == pending_reg2_conn) {
        pending_reg2_conn = NULL;
      }

      if (c->fd != BAD_SOCK) {
        remove_active_fd(c->fd);
        close_sock(c->fd);
      }
      *prev = c->next;
      free(c);
    } else {
      prev = &c->next;
    }
  }
}

void schedule_update_conns(int signal) {
  do_update_conns = 1;
}

int open_socket(conn_t *c, int quiet) {
  if (c->fd != BAD_SOCK) {
    remove_active_fd(c->fd);
    close_sock(c->fd);
    c->fd = BAD_SOCK;
  }

  // Set up the socket
  sock_t fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd == BAD_SOCK) {
    err("Failed to open a socket");
    return -1;
  }
  set_nonblock(fd);

  int bufsize = SEND_BUF_SIZE;
  int ret = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, (const char *)&bufsize, sizeof(bufsize));
  if (ret != 0) {
    err("failed to set send buffer size (%d)\n", bufsize);
    goto err;
  }

  // Bind it to the source address
  ret = bind(fd, &c->src, sizeof(c->src));
  if (ret != 0) {
    if (!quiet) {
      err("Failed to bind to the source address %s\n", print_addr(&c->src));
    }
    goto err;
  }

  add_active_fd(fd);
  c->fd = fd;

  return 0;

err:
  close_sock(fd);
  return -1;
}

int open_conns(char *host, char *port) {
  // Check that we can actually open & bind at least one socket
  int opened = 0;
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (open_socket(c, 0) == 0) {
      opened++;
    }
  }
  return opened;
}

/*

Connection housekeeping

*/
void set_srtla_addr(struct addrinfo *addr) {
  memcpy(&srtla_addr, addr->ai_addr, addr->ai_addrlen);
  info("Trying to connect to %s...\n", print_addr(&srtla_addr));
}

void send_keepalive(conn_t *c) {
  debug("%s (%p): sending keepalive\n", print_addr(&c->src), c);
  uint16_t pkt = htobe16_(SRTLA_TYPE_KEEPALIVE);
  // ignoring the result on purpose
  sendto(c->fd, (const char *)&pkt, sizeof(pkt), 0, &srtla_addr, addr_len);
}

#define HOUSEKEEPING_INT 1000 // ms
void connection_housekeeping() {
  static uint64_t all_failed_at = 0;
  /* We use milliseconds here because with a seconds timer we may be
     resending a second REG2 very soon after the first one, depending
     on when the first execution happens within the seconds interval */
  static uint64_t last_ran = 0;
  uint64_t ms;
  assert(get_ms(&ms) == 0);
  if ((last_ran + HOUSEKEEPING_INT) > ms) return;

  time_t time = (time_t)(ms / 1000);

  active_connections = 0;

  if (pending_reg2_conn && time > pending_reg_timeout) {
    pending_reg2_conn = NULL;
  }

  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->fd == BAD_SOCK) {
      open_socket(c, 1);
      continue;
    }

    if (conn_timed_out(c, time)) {
      /* When we first detect the connection having failed,
         we reset its status and print a message */
      if (c->last_rcvd > 0) {
        info("%s (%p): connection failed, attempting to reconnect\n",
             print_addr(&c->src), c);
        c->last_rcvd = 0;
        c->last_sent = 0;
        c->window = WINDOW_MIN * WINDOW_MULT;
        c->in_flight_pkts = 0;
        for (int i = 0; i < PKT_LOG_SZ; i++) {
          c->pkt_log[i] = -1;
        }
      }

      if (pending_reg2_conn == NULL) {
        /* As the connection has timed out on our end, the receiver might have garbage
           collected it. Try to re-establish it rather than send a keepalive */
        send_reg2(c);
      } else if (pending_reg2_conn == c) {
        send_reg1(c);
      }
      continue;
    }

    /* If a connection has received data in the last CONN_TIMEOUT seconds,
       then it's active */
    active_connections++;

    if ((c->last_sent + IDLE_TIME) < time) {
      send_keepalive(c);
    }
  }

  if (active_connections == 0) {
    if (all_failed_at == 0) {
      all_failed_at = ms;
    }

    if (has_connected) {
      err("warning: no available connections\n");
    }

    // Timeout when all connections have failed
    if (ms > (all_failed_at + (GLOBAL_TIMEOUT * 1000))) {
      if (has_connected) {
        err("Failed to re-establish any connections to %s\n",
            print_addr(&srtla_addr));
        exit(EXIT_FAILURE);
      }

      err("Failed to establish any initial connections to %s\n",
          print_addr(&srtla_addr));

      // Walk through the list of resolved addresses
      if (addrs->ai_next) {
        addrs = addrs->ai_next;
        set_srtla_addr(addrs);
        all_failed_at = 0;
      } else {
        exit(EXIT_FAILURE);
      }
    }
  } else {
    all_failed_at = 0;
  }

  last_ran = ms;
}

#define ARG_LISTEN_PORT (argv[1])
#define ARG_SRTLA_HOST  (argv[2])
#define ARG_SRTLA_PORT  (argv[3])
#define ARG_IPS_FILE    (argv[4])
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "-v") == 0) {
    printf(VERSION "\n");
    exit(0);
  }
  if (argc != 5) exit_help();
  setvbuf(stdout, NULL, _IONBF, 0);
#ifdef _WIN32
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { fprintf(stderr, "WSAStartup failed\n"); exit(EXIT_FAILURE); }
#endif

  source_ip_file = ARG_IPS_FILE;
  int conn_count = setup_conns(source_ip_file);
  if (conn_count <= 0) {
    fprintf(stderr, "Failed to parse any IP addresses in %s\n", source_ip_file);
    exit(EXIT_FAILURE);
  }

  struct sockaddr_in listen_addr;

  int port = parse_port(ARG_LISTEN_PORT);
  if (port < 0) exit_help();

  // Read a random connection group id for this session
  random_bytes(srtla_id, SRTLA_ID_LEN);

  FD_ZERO(&active_fds);

  listen_addr.sin_family = AF_INET;
  listen_addr.sin_addr.s_addr = INADDR_ANY;
  listen_addr.sin_port = htons(port);
  listenfd = socket(AF_INET, SOCK_DGRAM, 0);
  if (listenfd == BAD_SOCK) { 
    perror("socket creation failed"); 
    exit(EXIT_FAILURE); 
  }

  int ret = bind(listenfd, (struct sockaddr *)&listen_addr, sizeof(listen_addr));
  if (ret < 0) { 
    perror("bind failed"); 
    exit(EXIT_FAILURE); 
  }
#ifdef _WIN32
  { BOOL f = FALSE; DWORD r = 0;
    WSAIoctl(listenfd, SIO_UDP_CONNRESET, &f, sizeof(f), NULL, 0, &r, NULL, NULL); }
#endif
  add_active_fd(listenfd);

  int connected = open_conns(ARG_SRTLA_HOST, ARG_SRTLA_PORT);
  if (connected < 1) {
    err("Failed to open and bind to any of the IP addresses in %s\n", source_ip_file);
    exit(EXIT_FAILURE);
  }

  // Resolve the address of the receiver
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  ret = getaddrinfo(ARG_SRTLA_HOST, ARG_SRTLA_PORT, &hints, &addrs);
  if (ret != 0) {
    err("Failed to resolve %s: %s\n", ARG_SRTLA_HOST, gai_strerror(ret));
    exit(EXIT_FAILURE);
  }

  set_srtla_addr(addrs);

#ifndef _WIN32
  signal(SIGHUP, schedule_update_conns);
#endif
  static char ips_prev[65536], ips_cur[65536];
  read_whole(source_ip_file, ips_prev, sizeof(ips_prev));
  uint64_t next_ips_check = mono_ms() + 1000;

  int info_int = LOG_PKT_INT;

  while(1) {
    if (mono_ms() >= next_ips_check) {
      next_ips_check = mono_ms() + 1000;
      if (read_whole(source_ip_file, ips_cur, sizeof(ips_cur)) == 0 && strcmp(ips_cur, ips_prev) != 0) {
        memcpy(ips_prev, ips_cur, sizeof(ips_prev));
        do_update_conns = 1;
      }
    }
    if (do_update_conns) {
      update_conns(source_ip_file);
      do_update_conns = 0;
    }

    connection_housekeeping();

    fd_set read_fds = active_fds;
    struct timeval to = {.tv_sec = 0, .tv_usec = 200*1000};
    ret = select(FD_SETSIZE, &read_fds, NULL, NULL, &to);
#ifdef _WIN32
    if (ret < 0) { Sleep(50); continue; }  /* niciun socket activ -> WSAEINVAL */
#endif

    if (ret > 0) {
      if (FD_ISSET(listenfd, &read_fds)) {
        handle_srt_data(listenfd);
      }

      for (conn_t *c = conns; c != NULL; c = c->next) {
        if (c->fd != BAD_SOCK && FD_ISSET(c->fd, &read_fds)) {
          handle_srtla_data(c);
        }
      }
    } // ret > 0

    info_int--;
    if (info_int == 0) {
      for (conn_t *c = conns; c != NULL; c = c->next) {
        debug("%s (%p): in flight: %d, window: %d, last_rcvd %ld\n",
              print_addr(&c->src), c, c->in_flight_pkts, c->window, (long)c->last_rcvd);
      }
      info_int = LOG_PKT_INT;
    }
  } // while(1);
}
