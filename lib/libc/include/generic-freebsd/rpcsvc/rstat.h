/*
 * Please do not edit this file.
 * It was generated using rpcgen.
 */

#ifndef _RSTAT_H_RPCGEN
#define	_RSTAT_H_RPCGEN

#include <rpc/rpc.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef FSCALE
/*
 * Scale factor for scaled integers used to count load averages.
 */
#define FSHIFT 8 /* bits to right of fixed binary point */
#define FSCALE (1<<FSHIFT)

#endif /* ndef FSCALE */
#define	RSTAT_CPUSTATES 4
#define	RSTAT_DK_NDRIVE 4

struct rstat_timeval {
	u_int tv_sec;
	u_int tv_usec;
};
typedef struct rstat_timeval rstat_timeval;

struct statstime {
	int cp_time[RSTAT_CPUSTATES];
	int dk_xfer[RSTAT_DK_NDRIVE];
	u_int v_pgpgin;
	u_int v_pgpgout;
	u_int v_pswpin;
	u_int v_pswpout;
	u_int v_intr;
	int if_ipackets;
	int if_ierrors;
	int if_oerrors;
	int if_collisions;
	u_int v_swtch;
	int avenrun[3];
	rstat_timeval boottime;
	rstat_timeval curtime;
	int if_opackets;
};
typedef struct statstime statstime;

struct statsswtch {
	int cp_time[RSTAT_CPUSTATES];
	int dk_xfer[RSTAT_DK_NDRIVE];
	u_int v_pgpgin;
	u_int v_pgpgout;
	u_int v_pswpin;
	u_int v_pswpout;
	u_int v_intr;
	int if_ipackets;
	int if_ierrors;
	int if_oerrors;
	int if_collisions;
	u_int v_swtch;
	u_int avenrun[3];
	rstat_timeval boottime;
	int if_opackets;
};
typedef struct statsswtch statsswtch;

struct stats {
	int cp_time[RSTAT_CPUSTATES];
	int dk_xfer[RSTAT_DK_NDRIVE];
	u_int v_pgpgin;
	u_int v_pgpgout;
	u_int v_pswpin;
	u_int v_pswpout;
	u_int v_intr;
	int if_ipackets;
	int if_ierrors;
	int if_oerrors;
	int if_collisions;
	int if_opackets;
};
typedef struct stats stats;

enum clnt_stat rstat(char *, struct statstime *);
int havedisk(char *);


#define	RSTATPROG ((unsigned long)(100001))
#define	RSTATVERS_TIME ((unsigned long)(3))

extern  void rstatprog_3(struct svc_req *rqstp, SVCXPRT *transp);
#define	RSTATPROC_STATS ((unsigned long)(1))
extern  statstime * rstatproc_stats_3(void *, CLIENT *);
extern  statstime * rstatproc_stats_3_svc(void *, struct svc_req *);
#define	RSTATPROC_HAVEDISK ((unsigned long)(2))
extern  u_int * rstatproc_havedisk_3(void *, CLIENT *);
extern  u_int * rstatproc_havedisk_3_svc(void *, struct svc_req *);
extern int rstatprog_3_freeresult(SVCXPRT *, xdrproc_t, caddr_t);
#define	RSTATVERS_SWTCH ((unsigned long)(2))

extern  void rstatprog_2(struct svc_req *rqstp, SVCXPRT *transp);
extern  statsswtch * rstatproc_stats_2(void *, CLIENT *);
extern  statsswtch * rstatproc_stats_2_svc(void *, struct svc_req *);
extern  u_int * rstatproc_havedisk_2(void *, CLIENT *);
extern  u_int * rstatproc_havedisk_2_svc(void *, struct svc_req *);
extern int rstatprog_2_freeresult(SVCXPRT *, xdrproc_t, caddr_t);
#define	RSTATVERS_ORIG ((unsigned long)(1))

extern  void rstatprog_1(struct svc_req *rqstp, SVCXPRT *transp);
extern  stats * rstatproc_stats_1(void *, CLIENT *);
extern  stats * rstatproc_stats_1_svc(void *, struct svc_req *);
extern  u_int * rstatproc_havedisk_1(void *, CLIENT *);
extern  u_int * rstatproc_havedisk_1_svc(void *, struct svc_req *);
extern int rstatprog_1_freeresult(SVCXPRT *, xdrproc_t, caddr_t);

/* the xdr functions */
extern  bool_t xdr_rstat_timeval(XDR *, rstat_timeval*);
extern  bool_t xdr_statstime(XDR *, statstime*);
extern  bool_t xdr_statsswtch(XDR *, statsswtch*);
extern  bool_t xdr_stats(XDR *, stats*);

#ifdef __cplusplus
}
#endif

#endif /* !_RSTAT_H_RPCGEN */