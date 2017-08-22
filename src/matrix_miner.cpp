// Cuckoo Cycle, a memory-hard proof-of-work
// Copyright (c) 2013-2017 John Tromp

#include "matrix_miner.hpp"
#include <unistd.h>
#include <sys/time.h>

#include "cuckoo_miner/matrix_miner_adds.h"

// arbitrary length of header hashed into siphash key
#define HEADERLEN 80

extern "C" int cuckoo_call(char* header_data, 
                           int header_length,
                           u32* sol_nonces){

  assert(NUM_THREADS_PARAM>0);

  print_buf("Coming in is: ", (const unsigned char*) &header_data, header_length);

  u32 nonce = 0;
  u32 range = 1;
  bool showcycle = false;
  struct timeval time0, time1;
  u32 timems;
  //char header[HEADERLEN];
  //u32 len;
  //int c;

  /*memset(header, 0, sizeof(header));
  while ((c = getopt (argc, argv, "h:m:n:r:st:x:")) != -1) {
    switch (c) {
      case 'h':
        len = strlen(optarg);
        assert(len <= sizeof(header));
        memcpy(header, optarg, len);
        break;
      case 'x':
        len = strlen(optarg)/2;
        assert(len == sizeof(header));
        for (u32 i=0; i<len; i++)
          sscanf(optarg+2*i, "%2hhx", header+i);
        break;
      case 'n':
        nonce = atoi(optarg);
        break;
      case 'r':
        range = atoi(optarg);
        break;
      case 'm':
        ntrims = atoi(optarg) & -2; // make even as required by solve()
        break;
      case 's':
        showcycle = true;
        break;
      case 't':
        nthreads = atoi(optarg);
        break;
    }
  }
  printf("Looking for %d-cycle on cuckoo%d(\"%s\",%d", PROOFSIZE, EDGEBITS+1, header, nonce);
  if (range > 1)
    printf("-%d", nonce+range-1);
  printf(") with 50%% edges\n");
  */
  solver_ctx ctx(NUM_THREADS_PARAM, NUM_TRIMS_PARAM, showcycle);

  u32 sbytes = ctx.sharedbytes();
  u32 tbytes = ctx.threadbytes();
  int sunit,tunit;
  for (sunit=0; sbytes >= 10240; sbytes>>=10,sunit++) ;
  for (tunit=0; tbytes >= 10240; tbytes>>=10,tunit++) ;
  printf("Using %d%cB bucket memory at %lx,\n", sbytes, " KMGT"[sunit], (u64)ctx.trimmer->buckets);
  printf("%dx%d%cB thread memory at %lx,\n", NUM_THREADS_PARAM, tbytes, " KMGT"[tunit], (u64)ctx.trimmer->tbuckets);
  printf("%d-way siphash, and %d buckets.\n", NSIPHASH, NX);

  thread_ctx *threads = (thread_ctx *)calloc(NUM_THREADS_PARAM, sizeof(thread_ctx));
  assert(threads);

  u32 sumnsols = 0;
  for (u32 r = 0; r < range; r++) {
    gettimeofday(&time0, 0);
    //ctx.setheadernonce(header_data, header_length, nonce + r);
    ctx.setheadergrin(header_data, header_length);
    printf("k0 k1 %lx %lx\n", ctx.trimmer->sip_keys.k0, ctx.trimmer->sip_keys.k1);
    u32 nsols = ctx.solve();
    gettimeofday(&time1, 0);
    timems = (time1.tv_sec-time0.tv_sec)*1000 + (time1.tv_usec-time0.tv_usec)/1000;
    printf("Time: %d ms\n", timems);

    for (unsigned s = 0; s < ctx.nsols; s++) {
      printf("Solution");
      //just return with the first solution we get
      for (int i = 0; i < PROOFSIZE; i++) {
        printf(" %jx", (uintmax_t)ctx.sols[s][i]);
        sol_nonces[i] = ctx.sols[s][i]; 
      }
      free(threads);
      printf("\n");
      hashes_processed_count++;
      return 1;
    }
    sumnsols += ctx.nsols;
  }
  free(threads);
  hashes_processed_count++;
  printf("%d total solutions\n", sumnsols);
  return 0;

}
