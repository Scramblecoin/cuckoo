#include <stdint.h>
#include <string.h>
#include "cuckoo.h"
#include <sys/time.h>

#include "cuckoo_miner/cuda_miner_adds.h"

// d(evice s)ipnode
#if (__CUDA_ARCH__  >= 320) // redefine ROTL to use funnel shifter, 3% speed gain

static __device__ __forceinline__ uint2 operator^ (uint2 a, uint2 b) { return make_uint2(a.x ^ b.x, a.y ^ b.y); }
static __device__ __forceinline__ void operator^= (uint2 &a, uint2 b) { a.x ^= b.x, a.y ^= b.y; }
static __device__ __forceinline__ void operator+= (uint2 &a, uint2 b) {
  asm("{\n\tadd.cc.u32 %0,%2,%4;\n\taddc.u32 %1,%3,%5;\n\t}\n\t"
    : "=r"(a.x), "=r"(a.y) : "r"(a.x), "r"(a.y), "r"(b.x), "r"(b.y));
}
#undef ROTL
__inline__ __device__ uint2 ROTL(const uint2 a, const int offset) {
  uint2 result;
  if (offset >= 32) {
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.x) : "r"(a.x), "r"(a.y), "r"(offset));
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.y) : "r"(a.y), "r"(a.x), "r"(offset));
  } else {
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.x) : "r"(a.y), "r"(a.x), "r"(offset));
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.y) : "r"(a.x), "r"(a.y), "r"(offset));
  }
  return result;
}
__device__ __forceinline__ uint2 vectorize(const uint64_t x) {
  uint2 result;
  asm("mov.b64 {%0,%1},%2; \n\t" : "=r"(result.x), "=r"(result.y) : "l"(x));
  return result;
}
__device__ __forceinline__ uint64_t devectorize(uint2 x) {
  uint64_t result;
  asm("mov.b64 %0,{%1,%2}; \n\t" : "=l"(result) : "r"(x.x), "r"(x.y));
  return result;
}
__device__ node_t dipnode(siphash_keys &keys, edge_t nce, u32 uorv) {
  uint2 nonce = vectorize(2*nce + uorv);
  uint2 v0 = vectorize(keys.k0), v1 = vectorize(keys.k1), v2 = vectorize(keys.k2), v3 = vectorize(keys.k3) ^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= vectorize(0xff);
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return devectorize(v0 ^ v1 ^ v2  ^ v3) & EDGEMASK;
}

#else

__device__ node_t dipnode(siphash_keys &keys, edge_t nce, u32 uorv) {
  u64 nonce = 2*nce + uorv;
  u64 v0 = keys.k0, v1 = keys.k0, v2 = keys.k2, v3 = keys.k3^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= 0xff;
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return (v0 ^ v1 ^ v2  ^ v3) & EDGEMASK;
}

#endif

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <vector>
#include <bitset>

// algorithm/performance parameters

// EDGEBITS/NEDGES/EDGEMASK defined in cuckoo.h

// The node bits are logically split into 3 groups:
// XBITS 'X' bits (most significant), YBITS 'Y' bits, and ZBITS 'Z' bits (least significant)
// Here we have the default XBITS=YBITS=7, ZBITS=15 summing to EDGEBITS=29
// nodebits   XXXXXXX YYYYYYY ZZZZZZZZZZZZZZZ
// bit%10     8765432 1098765 432109876543210
// bit/10     2222222 2111111 111110000000000

// The matrix solver stores all edges in a matrix of NX * NX buckets,
// where NX=2^XBITS is the number of possible values of the 'X' bits.
// Edge i between nodes ui = siphash24(2*i) and vi = siphash24(2*i+1)
// resides in the bucket at (uiX,viX)
// In each trimming round, either a matrix row or a matrix column (NX buckets)
// is bucket sorted on uY or vY respectively, and then within each bucket
// uZ or vZ values are counted and edges with a count of only one are eliminated,
// while remaining edges are bucket sorted back on vY or uY respectively.
// When sufficiently many edges have been eliminated, a pair of compression
// rounds remap surviving Z values in each X,Y bucket to fit into 15-YBITS bits,
// allowing the remaining rounds to avoid the sorting on Y and directly
// count YZ values in a cache friendly 32KB.

#ifndef XBITS
// 7 seems to give best performance
#define XBITS 7
#endif

#define YBITS XBITS

// size in bytes of a big bucket entry
#ifndef BIGSIZE
#define BIGSIZE 5
#endif

// YZ compression round; must be even
#ifndef COMPRESSROUND
#define COMPRESSROUND 16
#endif

typedef uint8_t u8;
typedef uint16_t u16;

// node bits have two groups of bucketbits (big and small) and a remaining group of degree bits
const static u32 NX        = 1 << XBITS;
const static u32 XMASK     = NX - 1;
const static u32 NY        = 1 << YBITS;
const static u32 YMASK     = NY - 1;
const static u32 XYBITS    = XBITS + YBITS;
const static u32 NXY       = 1 << XYBITS;
const static u32 ZBITS     = EDGEBITS - XYBITS;
const static u32 NZ        = 1 << ZBITS;
const static u32 ZMASK     = NZ - 1;
const static u32 YZBITS    = YBITS + ZBITS;
const static u32 NYZ       = 1 << YZBITS;
const static u32 YZMASK    = NYZ - 1;
const static u32 YZ1BITS   = 15;  // combined Y and compressed Z bits
const static u32 NYZ1      = 1 << YZ1BITS;
const static u32 MAXNZNYZ1 = NYZ1 > NZ ? NYZ1 : NZ;
const static u32 YZ1MASK   = NYZ1 - 1;
const static u32 Z1BITS    = YZ1BITS - YBITS;
const static u32 NZ1       = 1 << Z1BITS;
const static u32 Z1MASK    = NZ1 - 1;
const static u32 YZ2BITS   = 9;  // more compressed YZ bits
const static u32 NYZ2      = 1 << YZ2BITS;
const static u32 YZ2MASK   = NYZ2 - 1;
const static u32 Z2BITS    = YZ2BITS - YBITS;
const static u32 NZ2       = 1 << Z2BITS;
const static u32 Z2MASK    = NZ2 - 1;
const static u32 YZZBITS   = YZBITS + ZBITS;
const static u32 YZZ1BITS  = YZ1BITS + ZBITS;

const static u32 BIGSLOTBITS   = BIGSIZE * 8;
const static u32 NONYZBITS     = BIGSLOTBITS - YZBITS;
const static u32 NNONYZ        = 1 << NONYZBITS;

const static u32 Z2BUCKETSIZE = NYZ2 >> 3;

// for p close to 0, Pr(X>=k) < e^{-n*p*eps^2} where k=n*p*(1+eps)
// see https://en.wikipedia.org/wiki/Binomial_distribution#Tail_bounds
// eps should be at least 1/sqrt(n*p/64)
// to give negligible bad odds of e^-64.

// 1/32 reduces odds of overflowing z bucket on 2^30 nodes to 2^14*e^-32
// (less than 1 in a billion) in theory. not so in practice (fails first at cuda30 -n 1679)
#ifndef BIGEPS
#define BIGEPS 3/64
#endif

const static u32 ZBUCKETSLOTS = NZ + NZ * BIGEPS;
const static u32 ZBUCKETSIZE = ZBUCKETSLOTS * BIGSIZE;
const static u32 TBUCKETSIZE = ZBUCKETSLOTS * BIGSIZE;

template<u32 BUCKETSIZE, u32 NRENAME, u32 NRENAME1>
struct zbucket {
  u32 size;
  const static u32 RENAMESIZE = 2*NRENAME1 + 2*NRENAME;
  union {
    u8 bytes[BUCKETSIZE];
    struct {
      u32 words[BUCKETSIZE/sizeof(u32) - RENAMESIZE];
      u32 renameu1[NRENAME1];
      u32 renamev1[NRENAME1];
      u32 renameu[NRENAME];
      u32 renamev[NRENAME];
    };
  };
  __device__ void setsize(u8 const *end) {
    size = end - bytes;
    assert(size <= BUCKETSIZE);
  }
};

template <u32 SIZE>
class twice_set {
  const static u32 TWICE_WORDS = ((2 * SIZE) / 32);
public:
  u32 bits[TWICE_WORDS];
  __device__ void reset() {
    for (u32 b = threadIdx.x; b < TWICE_WORDS; b += blockDim.x)
      bits[b] = 0;
  }
  __device__ void set(node_t u) {
    node_t idx = u/16;
    u32 bit = 1 << (2 * (u%16));
    u32 old = atomicOr(&bits[idx], bit);
    u32 bit2 = bit<<1;
    if ((old & (bit2|bit)) == bit) atomicOr(&bits[idx], bit2);
  }
  __device__ u32 test(node_t u) const {
    return (bits[u/16] >> (2 * (u%16))) & 2;
  }
};

template<u32 BUCKETSIZE, u32 NR, u32 NR1>
struct indexer {
  u32 index[NX];
  zbucket<128,0,0> buf[NY];
  u32 bufindex[NX];
  zbucket<BUCKETSIZE, NR, NR1> (*buckets)[NY];

  __device__ void init(zbucket<BUCKETSIZE, NR, NR1> (*bkts)[NY]) {
    if (!threadIdx.x)
      buckets = bkts;
  }
  __device__ void matrixu(const u32 x) {
    for (u32 y = threadIdx.x; y < NY; y += blockDim.x)
      index[y] = buckets[x][y].bytes - (u8 *)buckets;
  }
  __device__ void matrixv(const u32 y) {
    for (u32 x = threadIdx.x; x < NX; x += blockDim.x)
      index[x] = buckets[x][y].bytes - (u8 *)buckets;
  }
  template <u32 SIZE>
  __device__ void writebig(u32 i, const u64 x) {
    const u32 idx = atomicAdd(index+i, SIZE);
    memcpy((u8 *)buckets + idx, (u8 *)&x, SIZE);
  }
  __device__ void write32(u32 i, const u32 x) {
    const u32 idx = atomicAdd(index+i, sizeof(u32));
    *(u32 *)((u8 *)buckets + idx) = x;
  }
  __device__ void storeu(const u32 x) {
    for (u32 y = threadIdx.x; y < NY; y += blockDim.x)
      buckets[x][y].setsize((u8 *)buckets + index[y]);
  }
  __device__ void storev(const u32 y) {
    for (u32 x = threadIdx.x; x < NX; x += blockDim.x)
      buckets[x][y].setsize((u8 *)buckets + index[x]);
  }
};

#define likely(x)   ((x)!=0)
#define unlikely(x) (x)

class edgetrimmer; // avoid circular references

typedef u8 zbucket8[NYZ1*2];
typedef u32 zbucket32[MAXNZNYZ1];

#define checkCudaErrors(ans) ({ int retval; retval = gpuAssert((ans), __FILE__, __LINE__); retval; })
inline int gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
  int device_id;
  cudaGetDevice(&device_id);
	//Only spit this to logs once, then flag device to stop trying
  if (code != cudaSuccess && !DEVICE_INFO[device_id].threw_error) {
    fprintf(stderr,"Device %d GPUassert: %s %s %d\n", device_id, cudaGetErrorString(code), file, line);
    cudaDeviceReset();
    mark_device_error(device_id);
    if (abort) return code;
  }
  return 0;
}

typedef u32 proof[PROOFSIZE];

struct twostagetpb {
  u16 stage1tpb;
  u16 stage2tpb;
};

struct trimparams {
  u16 nblocks;
  u16 ntrims;
  u16 genUblocks;
  u16 genUtpb;
  twostagetpb genV;
  twostagetpb trim;
  twostagetpb rename[2];
  u16 trim3tpb;
  u16 rename3tpb;
  u16 reportcount;
  u16 reportrounds;
  
  trimparams() {
    ntrims              = 176;
    nblocks             =  64;
    genUblocks          = 256;
    genUtpb             =   8;
    genV.stage1tpb      =  32;
    genV.stage2tpb      = 128;
    trim.stage1tpb      =  32;
    trim.stage2tpb      = 128;
    rename[0].stage1tpb =  32;
    rename[0].stage2tpb =  64;
    rename[1].stage1tpb =  32;
    rename[1].stage2tpb = 128;
    trim3tpb            =  64;
    rename3tpb          =   2;
    reportcount   = 1;
    reportrounds = 0;
  }
};

// maintains set of trimmable edges
struct edgetrimmer {
  trimparams tp;
  siphash_keys sip_keys;
  edgetrimmer *dt;
  zbucket<ZBUCKETSIZE,NZ1,NZ2> (*buckets)[NY];
  zbucket<TBUCKETSIZE,0,0> (*tbuckets)[NY];
  zbucket32 *tnames;
  u32 *uvnodes;
  proof sol;

  edgetrimmer(const trimparams _tp) {
    tp = _tp; // memcpy(tp, _tp, sizeof(trimparams));
    checkCudaErrors(cudaMalloc((void**)&dt, sizeof(edgetrimmer)));
    checkCudaErrors(cudaMalloc((void**)&buckets, sizeof(zbucket<ZBUCKETSIZE,NZ1,NZ2>[NX][NY])));
    checkCudaErrors(cudaMalloc((void**)&tbuckets, tp.nblocks * sizeof(zbucket<TBUCKETSIZE,0,0>[NY])));
    checkCudaErrors(cudaMalloc((void**)&tnames, tp.nblocks * sizeof(zbucket32)));
    checkCudaErrors(cudaMalloc((void**)&uvnodes, PROOFSIZE * 2 * sizeof(u32)));
  }
  u64 sharedbytes() const {
    return sizeof(zbucket<ZBUCKETSIZE,NZ1,NZ2>[NX][NY]);
  }
  u64 threadbytes() const {
    return sizeof(zbucket<TBUCKETSIZE,0,0>[NY]) + sizeof(zbucket32);
  }
  ~edgetrimmer() {
    checkCudaErrors(cudaFree(buckets));
    checkCudaErrors(cudaFree(tbuckets));
    checkCudaErrors(cudaFree(tnames));
    checkCudaErrors(cudaFree(uvnodes));
  }
  u32 count(u32 size_of) {
    u32 size, sumsize = 0;
    for (u32 ux = 0; ux < tp.reportcount; ux++)
      for (u32 vx = 0; vx < tp.reportcount; vx++) {
        cudaMemcpy(&size, &buckets[ux][vx].size, sizeof(u32), cudaMemcpyDeviceToHost);
        sumsize += size;
      }
    return sumsize / size_of;
  }

  template <u32 SIZE>
  __device__ void writebig(u8 *p64, const u64 x) {
    memcpy(p64, (u8 *)&x, SIZE);
  }

  __device__ u16 read16(const u8 *p64) {
    u16 foo;
    memcpy((u8 *)&foo, p64, 2);
    return foo;
  }

  template <u32 SIZE>
  __device__ u64 readbig(const u8 *p64) {
    u64 foo = 0;
    memcpy((u8 *)&foo, p64, SIZE);
    return foo;
  }

  __device__ void genUnodes(const u32 uorv) {
    __shared__ indexer<ZBUCKETSIZE,NZ1,NZ2> dst;

    dst.init(buckets);
    for (u32 y = blockIdx.x; y < NY; y += gridDim.x) {
      dst.matrixv(y);
      __syncthreads();
      u32 edge      = y << YZBITS;
      const u32 endedge = edge + NYZ;
      for (edge += threadIdx.x; edge < endedge; edge += blockDim.x) {
// bit        28..21     20..13    12..0
// node       XXXXXX     YYYYYY    ZZZZZ
        const u32 node = dipnode(sip_keys, edge, uorv);
        const u32 ux = node >> YZBITS;
// bit        39..21     20..13    12..0
// write        edge     YYYYYY    ZZZZZ
        dst.writebig<BIGSIZE>(ux, (u64)edge << YZBITS | (node & YZMASK));
      }
      __syncthreads();
      dst.storev(y);
    }
  }

  __device__ void genVnodes1(const u32 part) {
    __shared__ indexer<TBUCKETSIZE,0,0> small;

    small.init(&tbuckets[blockIdx.x]);
    const u32 ux = blockIdx.x + part * gridDim.x;
    {
      small.matrixu(0);
      __syncthreads();
      for (u32 my = 0 ; my < NY; my++) {
        u32 edge = my << YZBITS;
        const u8           *readbg = buckets[ux][my].bytes;
        const u8 * const endreadbg = readbg + buckets[ux][my].size;
// printf("id %d x %d y %d size %u read %d\n", blockIdx.x, ux, my, buckets[ux][my].size, readbg-base);
        for (readbg += BIGSIZE*threadIdx.x; readbg < endreadbg; readbg += BIGSIZE*blockDim.x) {
// bit     39/31..22     21..15    14..0
// read         edge     UYYYYY    UZZZZ   within UX partition
          const u64 e = readbig<BIGSIZE>(readbg);
// u32 oldedge = edge;
	  const u32 lag = NNONYZ >> 2;
          edge += (((u32)(e >> YZBITS) - edge + lag) & (NNONYZ-1)) - lag;
// if (blockIdx.x==4 && edge>oldedge+4096) printf("oldedge %x edge %x delta %d\n",  oldedge, edge, oldedge+NNONYZ-edge);
// if (ux==78 && my==243) printf("id %d ux %d my %d e %08x prefedge %x edge %x\n", blockIdx.x, ux, my, e, e >> YZBITS, edge);
          const u32 uy = (e >> ZBITS) & YMASK;
// bit         39..15     14..0
// write         edge     UZZZZ   within UX UY partition
          small.writebig<BIGSIZE>(uy, ((u64)edge << ZBITS) | (e & ZMASK));;

// printf("id %d ux %d y %d e %010lx e' %010x\n", blockIdx.x, ux, my, e, ((u64)edge << ZBITS) | (e >> YBITS));
        }
        if (unlikely(edge >> NONYZBITS != (((my+1) << YZBITS) - 1) >> NONYZBITS))
        { printf("OOPS1: id %d ux %d y %d edge %x vs %x\n", blockIdx.x, ux, my, edge, ((my+1)<<YZBITS)-1); assert(0); }
      }
      small.storeu(0);
    }
  }

  __device__ void genVnodes2(const u32 part, const u32 uorv) {
    static const u32 NONDEGBITS = (BIGSLOTBITS < 2 * YZBITS ? BIGSLOTBITS : 2 * YZBITS) - ZBITS;
    static const u32 NONDEGMASK = (1 << NONDEGBITS) - 1;
    __shared__ indexer<ZBUCKETSIZE,NZ1,NZ2> dst;
    __shared__ twice_set<NZ> degs;

    dst.init(buckets);
    const u32 ux = blockIdx.x + part * gridDim.x;
    {
      dst.matrixu(ux);
      for (u32 uy = 0 ; uy < NY; uy++) {
        degs.reset();
        __syncthreads();
        u8 *readsmall = tbuckets[blockIdx.x][uy].bytes, *endreadsmall = readsmall + tbuckets[blockIdx.x][uy].size;
// if (blockIdx.x==1) printf("id %d ux %d y %d size %u sumsize %u\n", blockIdx.x, ux, uy, tbuckets[blockIdx.x][uy].size/BIGSIZE, sumsize);
	readsmall += BIGSIZE * threadIdx.x;
        for (u8 *rdsmall = readsmall; rdsmall < endreadsmall; rdsmall+=BIGSIZE*blockDim.x)
	  degs.set(read16(rdsmall) & ZMASK);
        __syncthreads();
        u32 edge = 0;
	u64 uy34 = (u64)uy << YZZBITS;
        for (u8 *rdsmall = readsmall; rdsmall < endreadsmall; rdsmall+=BIGSIZE*blockDim.x) {
// bit         39..13     12..0
// read          edge     UZZZZ    sorted by UY within UX partition
          const u64 e = readbig<BIGSIZE>(rdsmall);
// u32 oldedge = edge;
	  const u32 lag = NONDEGMASK >> 2;
          edge += (((e >> ZBITS) - edge + lag) & NONDEGMASK) - lag;
// if (blockIdx.x==4 && edge>oldedge+1000000) printf("oldedge %x edge %x delta %d\n",  oldedge, edge, oldedge+NONDEGMASK+1-edge);
// if (blockIdx.x==0) printf("id %d ux %d uy %d e %010lx pref %4x edge %x mask %x\n", blockIdx.x, ux, uy, e, e>>ZBITS, edge, NONDEGMASK);
	  const u32 z = e & ZMASK;
          if (degs.test(z)) {
            const u32 node = dipnode(sip_keys, edge, uorv);
            const u32 vx = node >> YZBITS; // & XMASK;
// bit        39..34    33..21     20..13     12..0
// write      UYYYYY    UZZZZZ     VYYYYY     VZZZZ   within VX partition
            dst.writebig<BIGSIZE>(vx, uy34 | ((u64)z << YZBITS) | (node & YZMASK));
// printf("id %d ux %d y %d edge %08x e' %010lx vx %d\n", blockIdx.x, ux, uy, *readedge, uy34 | ((u64)(node & YZMASK) << ZBITS) | *readz, vx);
	  }
        }
        __syncthreads();
        if (unlikely(edge >> NONDEGBITS != EDGEMASK >> NONDEGBITS))
        { printf("OOPS2: id %d ux %d uy %d edge %x vs %x\n", blockIdx.x, ux, uy, edge, EDGEMASK); assert(0); }
      }
      dst.storeu(ux);
    }
  }

#define mymin(a,b) ((a) < (b) ? (a) : (b))

  template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
  __device__ void trimedges1(const u32 round, const u32 part) {
    static const u32 SRCSLOTBITS = mymin(SRCSIZE * 8, 2 * YZBITS);
    static const u32 SRCPREFBITS = SRCSLOTBITS - YZBITS;
    static const u32 SRCPREFMASK = (1 << SRCPREFBITS) - 1;
    __shared__ indexer<TBUCKETSIZE,0,0> small;

    small.init(&tbuckets[blockIdx.x]);
    const u32 vx = blockIdx.x + part * gridDim.x;
    {
      small.matrixu(0);
      for (u32 ux = 0; ux < NX; ux++) {
        __syncthreads();
        u32 uyz = 0;
        zbucket<ZBUCKETSIZE,NZ1,NZ2> &zb = TRIMONV ? buckets[ux][vx] : buckets[vx][ux];
        const u8 *readbg = zb.bytes;
        const u8 * const endreadbg = readbg + zb.size;
// if (!blockIdx.x && !threadIdx.x)
// printf("round %d vx %d ux %d size %u\n", round, vx, ux, pzb->size/SRCSIZE);
        for (readbg += SRCSIZE*threadIdx.x; readbg < endreadbg; readbg += SRCSIZE*blockDim.x) {
// bit     43/39..37    36..22     21..15     14..0
// write      UYYYYY    UZZZZZ     VYYYYY     VZZZZ   within VX partition
          const u64 e = readbig<SRCSIZE>(readbg); // & SRCSLOTMASK;
// if (!blockIdx.x && !threadIdx.x && round==4 && ux+vx==0)
// printf("id %d vx %d ux %d e %010llx suffUXYZ %05x suffUXY %03x UXYZ %08x UXY %04x mask %x\n", blockIdx.x, vx, ux, e, (u32)(e >> YZBITS), (u32)(e >> YZZBITS), uxyz, uxyz>>ZBITS, SRCPREFMASK);

	  const u32 lag = SRCPREFMASK >> 2;
          if (SRCPREFBITS >= YZBITS)
	    uyz = e >> YZBITS;
	  else uyz += (((u32)(e >> YZBITS) - uyz + lag) & SRCPREFMASK) - lag;
          const u32 vy = (e >> ZBITS) & YMASK;
// if (round==12)
//     printf("id %d.%d vx %d vy %d e1 %010lx e %010lx suffUX %02x UX %x\n", blockIdx.x, threadIdx.x, vx, vy, e1 , e, (u32)(e >> YZZBITS), ux);
// bit     43/39..37    36..30     29..15     14..0
// write      UXXXXX    UYYYYY     UZZZZZ     VZZZZ   within VX VY partition
          small.writebig<DSTSIZE>(vy, ((u64)(ux << YZBITS | uyz) << ZBITS) | (e & ZMASK));
          uyz &= ~ZMASK;
        }
        if (unlikely(uyz >> ZBITS >= NY))
        { printf("OOPS3: id %d vx %d ux %d uyz %x\n", blockIdx.x, vx, ux, uyz); break; }
      }
      small.storeu(0);
    }
  }

  template <u32 DSTSIZE, bool TRIMONV>
  __device__ void trimedges2(const u32 round, const u32 part) {
    static const u32 DSTSLOTBITS = mymin(DSTSIZE * 8, 2 * YZBITS);
    static const u32 DSTPREFBITS = DSTSLOTBITS - YZZBITS;
    static const u32 DSTPREFMASK = (1 << DSTPREFBITS) - 1;
    __shared__ indexer<ZBUCKETSIZE,NZ1,NZ2> dst;
    __shared__ twice_set<NZ> degs;

    dst.init(buckets);
    const u32 vx = blockIdx.x + part * gridDim.x;
    {
      TRIMONV ? dst.matrixv(vx) : dst.matrixu(vx);
      for (u32 vy = 0 ; vy < NY; vy++) {
        const u64 vy34 = (u64)vy << YZZBITS;
        degs.reset();
        __syncthreads();
        u8 *readsmall = tbuckets[blockIdx.x][vy].bytes, *endreadsmall = readsmall + tbuckets[blockIdx.x][vy].size;
// printf("id %d vx %d vy %d size %u sumsize %u\n", blockIdx.x, vx, vy, tbuckets[blockIdx.x][vx].size/BIGSIZE, sumsize);
        readsmall += DSTSIZE * threadIdx.x;
        for (u8 *rdsmall = readsmall; rdsmall < endreadsmall; rdsmall += DSTSIZE*blockDim.x)
	  degs.set(read16(rdsmall) & ZMASK);
        __syncthreads();
        u32 ux = 0;
        for (u8 *rdsmall = readsmall; rdsmall < endreadsmall; rdsmall += DSTSIZE*blockDim.x) {
// bit     41/39..34    33..26     25..13     12..0
// read       UXXXXX    UYYYYY     UZZZZZ     VZZZZ   within VX VY partition
// bit     45/39..37    36..30     29..15     14..0      with XBITS==YBITS==7
// read       UXXXXX    UYYYYY     UZZZZZ     VZZZZ   within VX VY partition
          const u64 e = readbig<DSTSIZE>(rdsmall); //  & DSTSLOTMASK;
	  const u32 lag = DSTPREFMASK >> 2;
          ux += (((u32)(e >> YZZBITS) - ux + lag) & DSTPREFMASK) - lag;
// if (round==12 && vx==0x49 && (e==0xec46dd5fa5ULL || e==0xed023593c3ULL || e==0xee6743a841ULL
//    || e==0xece4d1f4b3ULL || e==0xed26caec88ULL || e==0xf8523e9becULL))
//  printf("id %d.%d vx %d vy %d e %010lx suffUX %02x UX %x mask %x\n", blockIdx.x, threadIdx.x, vx, vy, e, (u32)(e >> YZZBITS), ux, DSTPREFMASK);
// bit    41/39..34    33..21     20..13     12..0
// write     VYYYYY    VZZZZZ     UYYYYY     UZZZZ   within UX partition
          if (degs.test(e & ZMASK))
            dst.writebig<DSTSIZE>(ux, vy34 | ((e & ZMASK) << YZBITS) | ((e >> ZBITS) & YZMASK));
        }
        __syncthreads();
        if (unlikely(ux >> DSTPREFBITS != XMASK >> DSTPREFBITS))
        { printf("OOPS4: id %d.%d vx %x ux %x vs %x\n", blockIdx.x, threadIdx.x, vx, ux, XMASK); }
      }
      TRIMONV ? dst.storev(vx) : dst.storeu(vx);
    }
  }

  template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
  __device__ void trimrename1(const u32 round, const u32 part) {
    static const u32 SRCSLOTBITS = mymin(SRCSIZE * 8, (TRIMONV ? YZBITS : YZ1BITS) + YZBITS);
    static const u32 SRCPREFBITS = SRCSLOTBITS - YZBITS;
    static const u32 SRCPREFMASK = (1 << SRCPREFBITS) - 1;
    __shared__ indexer<TBUCKETSIZE,0,0> small;

    small.init(&tbuckets[blockIdx.x]);
    const u32 vx = blockIdx.x + part * gridDim.x;
    {
      small.matrixu(0);
      for (u32 ux = 0 ; ux < NX; ux++) {
        __syncthreads();
        u32 uyz = 0;
        zbucket<ZBUCKETSIZE,NZ1,NZ2> &zb = TRIMONV ? buckets[ux][vx] : buckets[vx][ux];
        const u8 *readbg = zb.bytes;
	const u8 * const endreadbg = readbg + zb.size;
// printf("id %d vx %d ux %d size %u\n", blockIdx.x, vx, ux, zb.size/SRCSIZE);
        for (readbg += SRCSIZE*threadIdx.x; readbg < endreadbg; readbg += SRCSIZE*blockDim.x) {
// bit        39..37    36..22     21..15     14..0
// write      UYYYYY    UZZZZZ     VYYYYY     VZZZZ   within VX partition  if TRIMONV
// bit            36...22     21..15     14..0
// write          VYYYZZ'     UYYYYY     UZZZZ   within UX partition  if !TRIMONV
          const u64 e = readbig<SRCSIZE>(readbg); //  & SRCSLOTMASK;
	  const u32 lag = SRCPREFMASK >> 2;
          if (TRIMONV)
            uyz += (((u32)(e >> YZBITS) - uyz + lag) & SRCPREFMASK) - lag;
          else uyz = e >> YZBITS;
// if (round==32 && ux==25) printf("id %d vx %d ux %d e %010lx suffUXYZ %05x suffUXY %03x UXYZ %08x UXY %04x mask %x\n", blockIdx.x, vx, ux, e, (u32)(e >> YZBITS), (u32)(e >> YZZBITS), uxyz, uxyz>>ZBITS, SRCPREFMASK);
          const u32 vy = (e >> ZBITS) & YMASK;
// bit        39..37    36..30     29..15     14..0
// write      UXXXXX    UYYYYY     UZZZZZ     VZZZZ   within VX VY partition  if TRIMONV
// bit            36...30     29...15     14..0
// write          VXXXXXX     VYYYZZ'     UZZZZ   within UX UY partition  if !TRIMONV
          small.writebig<SRCSIZE>(vy, ((u64)(ux << (TRIMONV ? YZBITS : YZ1BITS) | uyz) << ZBITS) | (e & ZMASK));
// if (TRIMONV&&vx==75&&vy==83) printf("id %d vx %d vy %d e %010lx e15 %x ux %x\n", blockIdx.x, vx, vy, ((u64)uxyz << ZBITS) | (e & ZMASK), uxyz, uxyz>>YZBITS);
          if (TRIMONV)
            uyz &= ~ZMASK;
        }
      }
      small.storeu(0);
    }
  }

  template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
  __device__ void trimrename2(const u32 round, const u32 part) {
    static const u32 SRCSLOTBITS = mymin(SRCSIZE * 8, (TRIMONV ? YZBITS : YZ1BITS) + YZBITS);
    static const u32 SRCPREFBITS2 = SRCSLOTBITS - YZZBITS;
    static const u32 SRCPREFMASK2 = (1 << SRCPREFBITS2) - 1;
    __shared__ indexer<ZBUCKETSIZE,NZ1,NZ2> dst;
    __shared__ twice_set<NZ> degs;
    const u32 NONAME = ~0;
    u32 maxrename = 0;

    dst.init(buckets);
    const u32 vx = blockIdx.x + part * gridDim.x;
    {
      TRIMONV ? dst.matrixv(vx) : dst.matrixu(vx);
      u32 *names = tnames[blockIdx.x];
      u32 nrenames = threadIdx.x;
      for (u32 vy = 0 ; vy < NY; vy++) {
        for (u32 z = threadIdx.x; z < NZ; z += blockDim.x)
          names[z] = NONAME;
        degs.reset();
        __syncthreads();
        u8    *readsmall = tbuckets[blockIdx.x][vy].bytes, *endreadsmall = readsmall + tbuckets[blockIdx.x][vy].size;
// printf("id %d vx %d vy %d size %u sumsize %u\n", blockIdx.x, vx, vy, tbuckets[blockIdx.x][vx].size/BIGSIZE, sumsize);
        readsmall += SRCSIZE * threadIdx.x;
        for (u8 *rdsmall = readsmall; rdsmall < endreadsmall; rdsmall += SRCSIZE*blockDim.x)
	  degs.set(read16(rdsmall) & ZMASK);
        __syncthreads();
        u32 ux = 0;
        for (u8 *rdsmall = readsmall; rdsmall < endreadsmall; rdsmall += SRCSIZE*blockDim.x) {
// bit     41/39..34    33..26     25..13     12..0
// read       UXXXXX    UYYYYY     UZZZZZ     VZZZZ   within VX VY partition  if TRIMONV and XBITS==8
// bit        39..37    36..30     29..15     14..0
// read       UXXXXX    UYYYYY     UZZZZZ     VZZZZ   within VX VY partition  if TRIMONV
// bit            36...30     29...15     14..0
// read           VXXXXXX     VYYYZZ'     UZZZZ   within UX UY partition  if !TRIMONV
          const u64 e = readbig<SRCSIZE>(rdsmall); //  & SRCSLOTMASK;
	  const u32 lag = SRCPREFMASK2 >> 2;
          if (TRIMONV) {
            if (SRCPREFBITS2 >= XBITS)
	      ux = e >> YZZBITS;
	    else ux += (((u32)(e >> YZZBITS) - ux + lag) & SRCPREFMASK2) - lag;
	  } else ux = e >> YZZ1BITS;
          const u32 vz = e & ZMASK;
// if (TRIMONV&&vx==135&&vy==147) printf("id %d vx %d vy %d e %012llx e37 %x ux %x vz %d nrenames %d\n", threadIdx.x, vx, vy, e, (u32)(e>>YZZBITS), ux, vz, nrenames);
          if (degs.test(vz)) {
            u32 vdeg = atomicCAS(&names[vz], NONAME, nrenames);
            if (vdeg == NONAME) {
              vdeg = nrenames;
              if (TRIMONV)
	        buckets[vdeg >> Z1BITS][vx].renamev[vdeg & Z1MASK] = vy << ZBITS | vz;
	      else
	        buckets[vx][vdeg >> Z1BITS].renameu[vdeg & Z1MASK] = vy << ZBITS | vz;
	      nrenames += blockDim.x;
            }
// bit       36..22     21..15     14..0
// write     VYYZZ'     UYYYYY     UZZZZ   within UX partition  if TRIMONV
            if (TRIMONV)
               dst.writebig<DSTSIZE>(ux, ((u64)vdeg << YZBITS ) | ((e >> ZBITS) & YZMASK));
            else dst.write32(ux, (vdeg << YZ1BITS) | ((e >> ZBITS) & YZ1MASK));
// if (vx==44&&vy==58) printf("  id %d vx %d vy %d newe %010lx\n", blockIdx.x, vx, vy, vy28 | ((vdeg) << YZBITS) | ((e >> ZBITS) & YZMASK));
          }
        }
        __syncthreads();
        if (TRIMONV && unlikely(ux >> SRCPREFBITS2 != XMASK >> SRCPREFBITS2))
        { printf("OOPS6: id %d vx %d vy %d ux %x vs %x\n", blockIdx.x, vx, vy, ux, XMASK); break; }
      }
      if (nrenames > maxrename)
        maxrename = nrenames;
      TRIMONV ? dst.storev(vx) : dst.storeu(vx);
    }
    // if (!blockIdx.x && !threadIdx.x ) printf("maxrename %d\n", maxrename);
    assert(maxrename < NYZ1);
  }

  template <bool TRIMONV>
  __device__ void trimedges3(const u32 round) {
    __shared__ twice_set<NYZ1> degs;

    // if (!blockIdx.x && !threadIdx.x ) printf("%dx%d threads\n", gridDim.x, blockDim.x);
    for (u32 vx = blockIdx.x; vx < NY; vx += gridDim.x) {
      __syncthreads();
      degs.reset();
      __syncthreads();
      for (u32 ux = threadIdx.x ; ux < NX; ux += blockDim.x) {
        zbucket<ZBUCKETSIZE,NZ1,NZ2> &zb = TRIMONV ? buckets[ux][vx] : buckets[vx][ux];
        u32 *readbg = zb.words, *endreadbg = readbg + zb.size/sizeof(u32);
        // printf("id %d vx %d ux %d size %d\n", blockIdx.x, vx, ux, zb.size/SRCSIZE);
        for (; readbg < endreadbg; readbg++)
          degs.set(*readbg & YZ1MASK);
      }
      __syncthreads();
      for (u32 ux = threadIdx.x ; ux < NX; ux += blockDim.x) {
        zbucket<ZBUCKETSIZE,NZ1,NZ2> &zb = TRIMONV ? buckets[ux][vx] : buckets[vx][ux];
        u32 *readbg = zb.words, *endreadbg = readbg + zb.size/sizeof(u32);
        u32 *bwrite = readbg;
        for (; readbg < endreadbg; readbg++) {
// bit       29..23    22..15     14..8     7..0
// read      UYYYYY    UZZZZ'     VYYYY     VZZ'   within VX partition
          const u32 e = *readbg;
          const u32 vyz = e & YZ1MASK;
// bit       29..23    22..15     14..8     7..0
// write     VYYYYY    VZZZZ'     UYYYY     UZZ'   within UX partition
          if (degs.test(vyz))
            *bwrite++ = (vyz << YZ1BITS) | (e >> YZ1BITS);
// if (e==0x30951) printf("round %d id %d\ntest %d vx %d ux %d e %08x readbig %d\n", round, threadIdx.x, degs.test(vyz), vx, ux, e, readbg-zb.words);
        }
        zb.setsize((u8 *)bwrite);
      }
    }
  }

  template <bool TRIMONV>
  __device__ void trimrename3(const u32 round) {
    __shared__ twice_set<NYZ1> degs;
    const u32 NONAME = ~0;
    u32 maxrename = 0;

    u32 *names = tnames[blockIdx.x];
    for (u32 vx = blockIdx.x; vx < NY; vx += gridDim.x) {
      __syncthreads();
      for (u32 z = threadIdx.x; z < NYZ1; z += blockDim.x)
        names[z] = NONAME;
      degs.reset();
      __syncthreads();
      for (u32 ux = threadIdx.x; ux < NX; ux += blockDim.x) {
        zbucket<ZBUCKETSIZE,NZ1,NZ2> &zb = TRIMONV ? buckets[ux][vx] : buckets[vx][ux];
        u32 *readbg = zb.words, *endreadbg = readbg + zb.size/sizeof(u32);
        // printf("id %d vx %d ux %d size %d\n", blockIdx.x, vx, ux, zb.size/SRCSIZE);
        for (; readbg < endreadbg; readbg ++)
          degs.set(*readbg & YZ1MASK);
      }
      u32 nrenames = threadIdx.x;
      __syncthreads();
      for (u32 ux = threadIdx.x; ux < NX; ux += blockDim.x) {
        zbucket<ZBUCKETSIZE,NZ1,NZ2> &zb = TRIMONV ? buckets[ux][vx] : buckets[vx][ux];
        zbucket<Z2BUCKETSIZE,0,0> &wb = ((zbucket<Z2BUCKETSIZE,0,0> (*)[NY])tbuckets)[vx][ux];
        u32 *readbg = zb.words, *endreadbg = readbg + zb.size/sizeof(u32);
        u32 *bwrite = TRIMONV ? readbg : wb.words;
        for (; readbg < endreadbg; readbg ++) {
// bit       29...15     14...0
// read      UYYYZZ'     VYYZZ'   within VX partition
          const u32 e = *readbg;
          const u32 vyz = e & YZ1MASK;
          if (degs.test(vyz)) {
            u32 vdeg = atomicCAS(&names[vyz], NONAME, nrenames);
            if (vdeg == NONAME) {
              vdeg = nrenames;
              if (TRIMONV)
	        buckets[vdeg >> Z2BITS][vx].renamev1[vdeg & Z2MASK] = vyz;
	      else
	        buckets[vx][vdeg >> Z2BITS].renameu1[vdeg & Z2MASK] = vyz;
	      nrenames += blockDim.x;
#ifdef CHECKNAMES
	      if (nrenames >= NYZ2) {
                printf("OUT OF NAMES! Dropping %d edges from ux %d vx %d\n", (u32)(endreadbg-readbg-1), ux, vx);
                break;
              }
#endif
            }
// bit       23...15     14...0
// write     VYYZZZ"     UYYZZ'   within UX partition
            if (!TRIMONV && bwrite-wb.words >= Z2BUCKETSIZE/sizeof(u32)) {
              printf("BUCKET FULL! Dropping %d edges from ux %d vx %d\n", (u32)(endreadbg-readbg), ux, vx);
              break;
            }
            *bwrite++ = (vdeg << (TRIMONV ? YZ1BITS : YZ2BITS)) | (e >> YZ1BITS);
          }
        }
        if (TRIMONV) zb.size = (u8 *)bwrite - zb.bytes;
	else wb.setsize((u8 *)bwrite);
      }
      if (nrenames > maxrename)
        maxrename = nrenames;
    }
    assert(maxrename < NYZ2);
  }

  __device__ void recoveredges() {
    __shared__ u32 u, ux, uyz, v, vx, vyz;

    if (threadIdx.x == 0) {
      const u32 u1 = uvnodes[2*blockIdx.x], v1 = uvnodes[2*blockIdx.x+1];
      ux = u1 >> YZ2BITS;
      vx = v1 >> YZ2BITS;
      uyz = buckets[ux][(u1 >> Z2BITS) & YMASK].renameu1[u1 & Z2MASK];
      assert(uyz < NYZ1);
      vyz = buckets[(v1 >> Z2BITS) & YMASK][vx].renamev1[v1 & Z2MASK];
      assert(vyz < NYZ1);
#if COMPRESSROUND > 0
      uyz = buckets[ux][uyz >> Z1BITS].renameu[uyz & Z1MASK];
      vyz = buckets[vyz >> Z1BITS][vx].renamev[vyz & Z1MASK];
#endif
      u = (ux << YZBITS) | uyz;
      v = (vx << YZBITS) | vyz;
      uvnodes[2*blockIdx.x] = u;
      uvnodes[2*blockIdx.x+1] = v;
    }
    __syncthreads();
  }

  __device__ void recoveredges1() {
    __shared__ u32 uxymap[NXY/32];

    for (u32 i = threadIdx.x; i < PROOFSIZE; i += blockDim.x) {
      const u32 uxy = uvnodes[2*i] >> ZBITS;
      atomicOr(&uxymap[uxy/32], 1 << uxy%32);
    }
    __syncthreads();
    for (u32 edge = blockIdx.x * blockDim.x + threadIdx.x; edge < NEDGES; edge += gridDim.x * blockDim.x) {
      const u32 u = dipnode(sip_keys, edge, 0);
      const u32 uxy = u  >> ZBITS;
      if ((uxymap[uxy/32] >> uxy%32) & 1) {
	for (u32 j = 0; j < PROOFSIZE; j++) {
           if (uvnodes[2*j] == u && dipnode(sip_keys, edge, 1) == uvnodes[2*j+1]) {
             sol[j] = edge;
           }
        }
      }
    }
  }

  int trim();
  template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV> void _trimedges(edgetrimmer *et, const u32 round);
  template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV> void _trimrename(edgetrimmer *et, const u32 round);
};

__global__ void _genUnodes(edgetrimmer *et, const u32 uorv) {
  et->genUnodes(uorv);
}

__global__ void _genVnodes1(edgetrimmer *et, const u32 part) {
  et->genVnodes1(part);
}

__global__ void _genVnodes2(edgetrimmer *et, const u32 part, const u32 uorv) {
  et->genVnodes2(part, uorv);
}

template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
__global__ void _trimedges1(edgetrimmer *et, const u32 round, const u32 part) {
  et->trimedges1<SRCSIZE, DSTSIZE, TRIMONV>(round, part);
}

template <u32 DSTSIZE, bool TRIMONV>
__global__ void _trimedges2(edgetrimmer *et, const u32 round, const u32 part) {
  et->trimedges2<DSTSIZE, TRIMONV>(round, part);
}

template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
void edgetrimmer::_trimedges(edgetrimmer *et, const u32 round) {
  for (u32 part=0; part < NX/tp.nblocks; part++) {
    _trimedges1<SRCSIZE, DSTSIZE, TRIMONV><<<tp.nblocks,tp.trim.stage1tpb>>>(dt, round, part);
    _trimedges2<         DSTSIZE, TRIMONV><<<tp.nblocks,tp.trim.stage2tpb>>>(dt, round, part);
  }
}

template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
__global__ void _trimrename1(edgetrimmer *et, const u32 round, const u32 part) {
  et->trimrename1<SRCSIZE, DSTSIZE, TRIMONV>(round, part);
}

template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
__global__ void _trimrename2(edgetrimmer *et, const u32 round, const u32 part) {
  et->trimrename2<SRCSIZE, DSTSIZE, TRIMONV>(round, part);
}

template <u32 SRCSIZE, u32 DSTSIZE, bool TRIMONV>
void edgetrimmer::_trimrename(edgetrimmer *et, const u32 round) {
  for (u32 part=0; part < NX/tp.nblocks; part++) {
    _trimrename1<SRCSIZE, DSTSIZE, TRIMONV><<<tp.nblocks,tp.rename[round&1].stage1tpb>>>(dt, round, part);
    _trimrename2<SRCSIZE, DSTSIZE, TRIMONV><<<tp.nblocks,tp.rename[round&1].stage2tpb>>>(dt, round, part);
  }
}

template <bool TRIMONV>
__global__ void _trimedges3(edgetrimmer *et, const u32 round) {
  et->trimedges3<TRIMONV>(round);
}

template <bool TRIMONV>
__global__ void _trimrename3(edgetrimmer *et, const u32 round) {
  et->trimrename3<TRIMONV>(round);
}

__global__ void _recoveredges(edgetrimmer *et) {
  et->recoveredges();
}

__global__ void _recoveredges1(edgetrimmer *et) {
  et->recoveredges1();
}

#ifndef EXPANDROUND
#define EXPANDROUND 5
#endif

#if EXPANDROUND < COMPRESSROUND
#define BIGGERSIZE BIGSIZE+1
#else
#define BIGGERSIZE BIGSIZE
#endif

  int edgetrimmer::trim() {
    cudaMemcpy(dt, this, sizeof(edgetrimmer), cudaMemcpyHostToDevice);
    cudaEvent_t start, stop, startall, stopall;
    if (checkCudaErrors(cudaEventCreate(&startall))) return 0; if (checkCudaErrors(cudaEventCreate(&stopall))) return 0;
    cudaEventRecord(startall, NULL);
    if (checkCudaErrors(cudaEventCreate(&start))) return 0; if (checkCudaErrors(cudaEventCreate(&stop))) return 0;
    float duration;
    cudaEventRecord(start, NULL);
    _genUnodes<<<tp.genUblocks,tp.genUtpb>>>(dt, 0);
    if (checkCudaErrors(cudaDeviceSynchronize())) return 0; cudaEventRecord(stop, NULL);
    cudaEventSynchronize(stop); cudaEventElapsedTime(&duration, start, stop);
    if (0 < tp.reportrounds)
      printf("genUnodes size %u completed in %.0f ms\n", count(BIGSIZE), duration);
    cudaEventRecord(start, NULL);
    for (u32 part=0; part < NX/tp.nblocks; part++) {
      _genVnodes1<<<tp.nblocks,tp.genV.stage1tpb>>>(dt, part);
      _genVnodes2<<<tp.nblocks,tp.genV.stage2tpb>>>(dt, part, 1);
    }
    checkCudaErrors(cudaDeviceSynchronize()); cudaEventRecord(stop, NULL);
    cudaEventSynchronize(stop); cudaEventElapsedTime(&duration, start, stop);
    if (1 < tp.reportrounds)
      printf("genVnodes size %u completed in %.0f ms\n", count(BIGSIZE), duration);
    for (u32 round = 2; round < tp.ntrims-2; round += 2) {
      cudaEventRecord(start, NULL);
      u32 size_of = BIGGERSIZE;
      if (round < COMPRESSROUND) {
        if (round < EXPANDROUND) {
          _trimedges<BIGSIZE, BIGSIZE, true>(dt, round);
          size_of = BIGSIZE;
	} else if (round == EXPANDROUND) {
          _trimedges<BIGSIZE, BIGGERSIZE, true>(dt, round);
	} else _trimedges<BIGGERSIZE, BIGGERSIZE, true>(dt, round);
      } else if (round==COMPRESSROUND) {
        _trimrename<BIGGERSIZE, BIGGERSIZE, true>(dt, round);
      } else {
        _trimedges3<true><<<tp.nblocks,tp.trim3tpb>>>(dt, round);
        size_of = sizeof(u32);
      }
      checkCudaErrors(cudaDeviceSynchronize()); cudaEventRecord(stop, NULL);
      cudaEventSynchronize(stop); cudaEventElapsedTime(&duration, start, stop);
      if (round < tp.reportrounds)
        printf("round %d size %u completed in %.0f ms\n", round, count(size_of), duration);

      cudaEventRecord(start, NULL);
      size_of = BIGGERSIZE;
      if (round < COMPRESSROUND) {
        if (round+1 < EXPANDROUND) {
          _trimedges<BIGSIZE, BIGSIZE, false>(dt, round+1);
          size_of = BIGGERSIZE;
	} else if (round+1 == EXPANDROUND) {
          _trimedges<BIGSIZE, BIGGERSIZE, false>(dt, round+1);
	} else _trimedges<BIGGERSIZE, BIGGERSIZE, false>(dt, round+1);
      } else if (round==COMPRESSROUND) {
        _trimrename<BIGGERSIZE, sizeof(u32), false>(dt, round+1);
        size_of = sizeof(u32);
      } else {
        _trimedges3<false><<<tp.nblocks,tp.trim3tpb>>>(dt, round+1);
        size_of = sizeof(u32);
      }
      if (checkCudaErrors(cudaDeviceSynchronize())) return 0; cudaEventRecord(stop, NULL);
      cudaEventSynchronize(stop); cudaEventElapsedTime(&duration, start, stop);
      if (round+1 < tp.reportrounds)
        printf("round %d size %u completed in %.0f ms\n", round+1, count(size_of), duration);
    }

    // cudaEventRecord(start, NULL);
    _trimrename3<true ><<<tp.nblocks,tp.rename3tpb>>>(dt, tp.ntrims-2);
    if (checkCudaErrors(cudaDeviceSynchronize())) return 0; // cudaEventRecord(stop, NULL);
    // cudaEventSynchronize(stop); cudaEventElapsedTime(&duration, start, stop);
    // printf("rename3 size %u completed in %.0f ms\n", count(cnt,cnt), duration);

    // cudaEventRecord(start, NULL);
    _trimrename3<false><<<tp.nblocks,tp.rename3tpb>>>(dt, tp.ntrims-1);
    if (checkCudaErrors(cudaDeviceSynchronize())) return 0; // cudaEventRecord(stop, NULL);
    // cudaEventSynchronize(stop); cudaEventElapsedTime(&duration, start, stop);
    // printf("rename3 size %u completed in %.0f ms\n", count(cnt,cnt), duration);

    cudaEventRecord(stopall, NULL); cudaEventSynchronize(stopall); cudaEventElapsedTime(&duration, startall, stopall);
    printf("trim completed in %.0f ms\n", duration);
  }

#define NODEBITS (EDGEBITS + 1)

// grow with cube root of size, hardly affected by trimming
const static u32 MAXPATHLEN = 8 << ((NODEBITS+2)/3);

const static u32 CUCKOO_SIZE = 2 * NX * NYZ2;

int nonce_cmp(const void *a, const void *b) {
  return *(u32 *)a - *(u32 *)b;
}

class solver_ctx {
public:
  edgetrimmer *trimmer;
  zbucket<Z2BUCKETSIZE,0,0> (*buckets)[NY];
  u32 *cuckoo;
  u32 uvnodes[2*PROOFSIZE];
  std::bitset<NXY> uxymap;
  std::vector<u32> sols; // concatanation of all proof's indices

  solver_ctx(const trimparams tp) {
    trimmer = new edgetrimmer(tp);
    cuckoo = 0;
  }
  void setheadernonce(char* const headernonce, const u32 len, const u32 nonce) {
    ((u32 *)headernonce)[len/sizeof(u32)-1] = htole32(nonce); // place nonce at end
    setheader(headernonce, len, &trimmer->sip_keys);
    sols.clear();
  }
  void setheadergrin(const char* header, const u32 len) {
    setheader(header, len, &trimmer->sip_keys);
    sols.clear();
  }
  ~solver_ctx() {
    delete trimmer;
  }

  void recordedge(const u32 i, const u32 u2, const u32 v2) {
    uvnodes[2*i]   = u2/2;
    uvnodes[2*i+1] = v2/2;
  }

  void solution(const u32 *us, u32 nu, const u32 *vs, u32 nv) {
    u32 ni = 0;
    recordedge(ni++, *us, *vs);
    while (nu--)
      recordedge(ni++, us[(nu+1)&~1], us[nu|1]); // u's in even position; v's in odd
    while (nv--)
    recordedge(ni++, vs[nv|1], vs[(nv+1)&~1]); // u's in odd position; v's in even
    assert(ni == PROOFSIZE);
    sols.resize(sols.size() + PROOFSIZE);
    cudaMemcpy(trimmer->uvnodes, uvnodes, sizeof(uvnodes), cudaMemcpyHostToDevice);
    _recoveredges<<<PROOFSIZE,1>>>(trimmer->dt);
    _recoveredges1<<<4096,128>>>(trimmer->dt);
    cudaMemcpy(&sols[sols.size() - PROOFSIZE], trimmer->dt->sol, sizeof(trimmer->sol), cudaMemcpyDeviceToHost);
    qsort(&sols[sols.size()-PROOFSIZE], PROOFSIZE, sizeof(u32), nonce_cmp);
  }

  static const u32 CUCKOO_NIL = ~0;

  u32 path(u32 u, u32 *us) const {
    u32 nu, u0 = u;
    for (nu = 0; u != CUCKOO_NIL; u = cuckoo[u]) {
      if (nu >= MAXPATHLEN) {
        while (nu-- && us[nu] != u) ;
        if (!~nu)
          printf("maximum path length exceeded\n");
        else printf("illegal %4d-cycle from node %d\n", MAXPATHLEN-nu, u0);
        exit(0);
      }
      us[nu++] = u;
    }
    return nu-1;
  }

  void findcycles() {
    u32 us[MAXPATHLEN], vs[MAXPATHLEN];

    u32 sumsize = 0;
    for (u32 vx = 0; vx < NX; vx++) {
      for (u32 ux = 0 ; ux < NX; ux++) {
        zbucket<Z2BUCKETSIZE,0,0> &zb = buckets[ux][vx];
	u32 size = zb.size / sizeof(u32);
        u32 *readbg = zb.words, *endreadbg = readbg + size;
	sumsize += size;
        for (; readbg < endreadbg; readbg++) {
// bit        21..11     10...0
// write      UYYZZZ'    VYYZZ'   within VX partition
          const u32 e = *readbg;
	  assert(e < NYZ2*NYZ2);
          const u32 uxyz = (ux << YZ2BITS) | (e >> YZ2BITS);
          const u32 vxyz = (vx << YZ2BITS) | (e & YZ2MASK);
          const u32 u0 = uxyz << 1, v0 = (vxyz << 1) | 1;
          if (u0 != CUCKOO_NIL) {
            u32 nu = path(u0, us), nv = path(v0, vs);
// printf("vx %02x ux %02x e %08x uxyz %06x vxyz %06x u0 %x v0 %x nu %d nv %d\n", vx, ux, e, uxyz, vxyz, u0, v0, nu, nv);
            if (us[nu] == vs[nv]) {
              const u32 min = nu < nv ? nu : nv;
              for (nu -= min, nv -= min; us[nu] != vs[nv]; nu++, nv++) ;
              const u32 len = nu + nv + 1;
              printf("%4d-cycle found\n", len);
              if (len == PROOFSIZE)
                solution(us, nu, vs, nv);
            } else if (nu < nv) {
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
      }
    }
    printf("findcycles completed on %d edges\n", sumsize);
  }

  int solve() {
    if (!trimmer->trim()) return 0;
    buckets = new zbucket<Z2BUCKETSIZE,0,0>[NX][NY];
    printf("start cudaMemcpy\n");
    if (checkCudaErrors(cudaMemcpy(buckets, trimmer->tbuckets, sizeof(zbucket<Z2BUCKETSIZE,0,0>[NX][NY]), cudaMemcpyDeviceToHost))) {
        delete[] buckets;
        return 0;
    }
    printf("end cudaMemcpy\n");
    cuckoo = new u32[CUCKOO_SIZE];
    memset(cuckoo, (int)CUCKOO_NIL, CUCKOO_SIZE * sizeof(u32));
    findcycles();
    delete[] cuckoo;
    delete[] buckets;
    return sols.size() / PROOFSIZE;
  }
};

#include <unistd.h>

// arbitrary length of header hashed into siphash key
#define HEADERLEN 80

extern "C" int cuckoo_call(char* header_data,
                           int header_length,
                           u32* sol_nonces ) {
  u64 start_time=timestamp();
  trimparams tp;
  u32 nonce = 0;
  u32 range = 1;
  u32 device = 0;
  char header[HEADERLEN];
  u32 len, timems;
  struct timeval time0, time1;
  /*int c;
	  memset(header, 0, sizeof(header));
    while ((c = getopt(argc, argv, "sb:c:d:h:k:m:n:r:U:u:V:v:T:t:X:x:Y:y:Z:z:")) != -1) {
    switch (c) {
      case 's':
        printf("SYNOPSIS\n  cuda30 [-b sblocks] [-c count] [-d device] [-h hexheader] [-k rounds] [-m trims] [-n nonce] [-r range] [-U sblocks] [-u threads] [-V threads] [-v threads] [-T threads] [-t threads] [-X threads] [-x threads] [-Y threads] [-y threads] [-Z threads] [-z threads]\n");
        printf("DEFAULTS\n  cuda30 -b %d -c %d -d %d -h \"\" -k %d -m %d -n %d -r %d -U %d -u %d -V %d -v %d -T %d -t %d -X %d -x %d -Y %d -y 128 -Z 64 -z 2\n", tp.nblocks, tp.reportcount, device, tp.reportrounds, tp.ntrims, nonce, range, tp.genUblocks, tp.genUtpb, tp.genV.stage1tpb, tp.genV.stage2tpb, tp.trim.stage1tpb, tp.trim.stage2tpb, tp.rename[0].stage1tpb, tp.rename[0].stage2tpb, tp.rename[1].stage1tpb, tp.rename[1].stage1tpb, tp.trim3tpb, tp.rename3tpb);
        exit(0);
      case 'b':
        tp.nblocks = atoi(optarg);
        break;
      case 'd':
        device = atoi(optarg);
        break;
      case 'k':
        tp.reportrounds = atoi(optarg);
        break;
      case 'l':
        tp.reportcount = atoi(optarg);
        break;
      case 'h':
        len = strlen(optarg)/2;
        assert(len <= sizeof(header));
        for (u32 i=0; i<len; i++)
          sscanf(optarg+2*i, "%2hhx", header+i);
        break;
      case 'n':
        nonce = atoi(optarg);
        break;
      case 'm':
        tp.ntrims = atoi(optarg) & -2; // make even as required by solve()
        break;
      case 'r':
        range = atoi(optarg);
        break;
      case 'U':
        tp.genUblocks = atoi(optarg);
        break;
      case 'u':
        tp.genUtpb = atoi(optarg);
        break;
      case 'V':
        tp.genV.stage1tpb = atoi(optarg);
        break;
      case 'v':
        tp.genV.stage2tpb = atoi(optarg);
        break;
      case 'T':
        tp.trim.stage1tpb = atoi(optarg);
        break;
      case 't':
        tp.trim.stage2tpb = atoi(optarg);
        break;
      case 'X':
        tp.rename[0].stage1tpb = atoi(optarg);
        break;
      case 'x':
        tp.rename[0].stage2tpb = atoi(optarg);
        break;
      case 'Y':
        tp.rename[1].stage1tpb = atoi(optarg);
        break;
      case 'y':
        tp.rename[1].stage2tpb = atoi(optarg);
        break;
      case 'Z':
        tp.trim3tpb = atoi(optarg);
        break;
      case 'z':
        tp.rename3tpb = atoi(optarg);
        break;
    }
  }*/

  /*int nDevices;
  cudaGetDeviceCount(&nDevices);
  assert(device < nDevices);
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, device);
  u64 dbytes = prop.totalGlobalMem;
  int dunit;
  for (dunit=0; dbytes >= 10240; dbytes>>=10,dunit++) ;
  printf("%s with %d%cB @ %d bits x %dMHz\n", prop.name, (u32)dbytes, " KMGT"[dunit], prop.memoryBusWidth, prop.memoryClockRate/1000);
  cudaSetDevice(device);*/

  printf("Looking for %d-cycle on cuckoo%d(\"%s\",%d", PROOFSIZE, NODEBITS, header, nonce);
  if (range > 1)
    printf("-%d", nonce+range-1);
  printf(") with 50%% edges, %d*%d buckets, %d trims, and %d thread blocks.\n", NX, NY, tp.ntrims, tp.nblocks); 

  solver_ctx ctx(tp);

  u64 sbytes = ctx.trimmer->sharedbytes();
  u64 tbytes = ctx.trimmer->threadbytes();
  u64 bytes = sbytes + tp.nblocks * tbytes;
  int sunit,tunit,unit;
  for (sunit=0; sbytes >= 10240; sbytes>>=10,sunit++) ;
  for (tunit=0; tbytes >= 10240; tbytes>>=10,tunit++) ;
  for ( unit=0;  bytes >= 10240;  bytes>>=10, unit++) ;
  printf("Using %d%cB bucket memory and %d%cB memory per thread block (%d%cB total)\n",
    sbytes, " KMGT"[sunit], tbytes, " KMGT"[tunit], bytes, " KMGT"[unit], NX);

  u32 sumnsols = 0;
  for (int r = 0; r < range; r++) {
    gettimeofday(&time0, 0);
    //ctx.setheadernonce(header, sizeof(header), nonce + r);
    ctx.setheadergrin(header_data, header_length);
    printf("nonce %d k0 k1 k2 k3 %llx %llx %llx %llx\n", nonce+r,
       ctx.trimmer->sip_keys.k0, ctx.trimmer->sip_keys.k1, ctx.trimmer->sip_keys.k2, ctx.trimmer->sip_keys.k3);
    u32 nsols = ctx.solve();
    gettimeofday(&time1, 0);
    timems = (time1.tv_sec-time0.tv_sec)*1000 + (time1.tv_usec-time0.tv_usec)/1000;
    printf("Time: %d ms\n", timems);

    for (unsigned s = 0; s < nsols; s++) {
      printf("Solution");
      u32* prf = &ctx.sols[s * PROOFSIZE];
      for (u32 i = 0; i < PROOFSIZE; i++) {
        sol_nonces[i] = prf[i];
        printf(" %jx", (uintmax_t)prf[i]);
      }
      printf("\n");
      int pow_rc = verify(prf, &ctx.trimmer->sip_keys);
      if (pow_rc == POW_OK) {
        printf("Verified with cyclehash ");
        unsigned char cyclehash[32];
        blake2b((void *)cyclehash, sizeof(cyclehash), (const void *)prf, sizeof(proof), 0, 0);
        for (int i=0; i<32; i++)
          printf("%02x", cyclehash[i]);
        printf("\n");
      } else {
        printf("FAILED due to %s\n", errstr[pow_rc]);
      }
      //Just return first solution for now
      // TODO: Probably skip verify above
      if (SINGLE_MODE){
         update_stats(0, start_time);
      }
      return 1;
    }
    sumnsols += nsols;
  }
  printf("%d total solutions\n", sumnsols);
  if (SINGLE_MODE){
  printf("single mode\n");
      update_stats(0,start_time);
  }

  return 0;
}
