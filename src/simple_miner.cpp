// Cuckoo Cycle, a memory-hard proof-of-work
// Copyright (c) 2013-2016 John Tromp

#include "cuckoo.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <unistd.h>
#include <set>

// assume EDGEBITS < 31
#define NNODES (2 * NEDGES)
#define MAXPATHLEN 8192

class cuckoo_ctx {
public:
  siphash_keys sip_keys;
  edge_t easiness;
  node_t *cuckoo;

  cuckoo_ctx(const char* header, int header_size, edge_t easy_ness) {
    setheader(header, header_size, &sip_keys);
    easiness = easy_ness;
    cuckoo = (node_t *)calloc(1+NNODES, sizeof(node_t));
    assert(cuckoo != 0);
  }
  ~cuckoo_ctx() {
    free(cuckoo);
  }
};

int path(node_t *cuckoo, node_t u, node_t *us) {
  int nu;
  for (nu = 0; u; u = cuckoo[u]) {
    if (++nu >= MAXPATHLEN) {
      while (nu-- && us[nu] != u) ;
      if (nu < 0)
        printf("maximum path length exceeded\n");
      else printf("illegal % 4d-cycle\n", MAXPATHLEN-nu);
      exit(0);
    }
    us[nu] = u;
  }
  return nu;
}

typedef std::pair<node_t,node_t> edge;

void solution(cuckoo_ctx *ctx, node_t *us, int nu, node_t *vs, int nv) {
  std::set<edge> cycle;
  unsigned n;
  cycle.insert(edge(*us, *vs));
  while (nu--)
    cycle.insert(edge(us[(nu+1)&~1], us[nu|1])); // u's in even position; v's in odd
  while (nv--)
    cycle.insert(edge(vs[nv|1], vs[(nv+1)&~1])); // u's in odd position; v's in even
  printf("Solution");
  for (edge_t nonce = n = 0; nonce < ctx->easiness; nonce++) {
    edge e(sipnode(&ctx->sip_keys, nonce, 0), sipnode(&ctx->sip_keys, nonce, 1));
    if (cycle.find(e) != cycle.end()) {
      printf(" %x", nonce);
      cycle.erase(e);
    }
  }
  printf("\n");
}

void worker(cuckoo_ctx *ctx) {
  node_t *cuckoo = ctx->cuckoo;
  node_t us[MAXPATHLEN], vs[MAXPATHLEN];
  for (node_t nonce = 0; nonce < ctx->easiness; nonce++) {
    node_t u0 = sipnode(&ctx->sip_keys, nonce, 0);
    if (u0 == 0) continue; // reserve 0 as nil; v0 guaranteed non-zero
    node_t v0 = sipnode(&ctx->sip_keys, nonce, 1);
    node_t u = cuckoo[u0], v = cuckoo[v0];
    us[0] = u0;
    vs[0] = v0;
#ifdef SHOW
    for (unsigned j=1; j<NNODES; j++)
      if (!cuckoo[j]) printf("%2d:   ",j);
      else           printf("%2d:%02d ",j,cuckoo[j]);
    printf(" %x (%d,%d)\n", nonce,*us,*vs);
#endif
    int nu = path(cuckoo, u, us), nv = path(cuckoo, v, vs);
    if (us[nu] == vs[nv]) {
      int min = nu < nv ? nu : nv;
      for (nu -= min, nv -= min; us[nu] != vs[nv]; nu++, nv++) ;
      int len = nu + nv + 1;
      printf("% 4d-cycle found at %d%%\n", len, (int)(nonce*100L/ctx->easiness));
      if (len == PROOFSIZE)
        solution(ctx, us, nu, vs, nv);
      continue;
    }
    if (nu < nv) {
      while (nu--)
        cuckoo[us[nu+1]] = us[nu];
      cuckoo[u0] = v0;
    } else {
      while (nv--)
        cuckoo[vs[nv+1]] = vs[nv];
      cuckoo[v0] = u0;
    }
  }
}

int main(int argc, char **argv) {
  char header[32];
  //Just hardcoding a header in here for the sake of example

  #if GRIN_MOD == 1
  EDGEBITS=11;
  #endif

  char *hexstring = "A6C16443FC82250B49C7FAA3876E7AB89BA687918CB00C4C10D6625E3A2E7BCC";
  int i;
  uint8_t str_len = strlen(hexstring);

  for (i = 0; i < (str_len / 2); i++) {
      sscanf(hexstring + 2*i, "%02x", &header[i]);
  }

  int c, easipct = 50;
  /*while ((c = getopt (argc, argv, "e:h:")) != -1) {
    switch (c) {
      case 'e':
        easipct = atoi(optarg);
        break;
      case 'h':
        memcpy(header, optarg, strlen(optarg));
        break;
    }
  }*/
  assert(easipct >= 0 && easipct <= 100);
  printf("Looking for %d-cycle on cuckoo%d(\"%s\") with %d%% edges\n",
               PROOFSIZE, EDGEBITS+1, header, easipct);
  u64 easiness = easipct * NNODES / 100;
  cuckoo_ctx ctx(header, 32, easiness);
  printf("k0 %lx k1 %lx\n", ctx.sip_keys.k0, ctx.sip_keys.k1);
  worker(&ctx);
}
