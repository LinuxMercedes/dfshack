#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

#define DO_STAT 0
#define DO_FCREATE 1
#define DO_LINK 1
#define DO_UNLINK 1
#define DO_WAIT 0
#define DO_SECOND_READ 0

int main()
{
  const char* fname = "file.txt";
  const char* lname = "link.txt";
  const char* fdata = "#\n# Edit Lock-Stake file. CAUTION: Please do not change.\n#\n# Information about current Edit Lock Owner.\n#\nLockStakeVersion               1.1\nLoginName                      nmjxv3\nHostName                       r07ses8t7.managed.mst.edu\nProcessIdentifier              10284\nProcessCreationTime_UTC        1365704606\nProcessCreationTime_Readable   Thu Apr 11 13:23:26 2013 CDT\nAppIdentifier                  OA File System Design Manager\nOSType                         unix\nReasonForPlacingEditLock       OpenAccess edit lock\nFilePathUsedToEditLock         /usr/local/home/nmjxv3/dfshack/mount/asdf7/PadBoxX/layout/layout.oa.cdslck\nTimeEditLocked                 Thu Apr 11 13:23:34 2013 CDT\n";

  int lfd, ffd;
  char buf[4096];
  int ret;
  struct stat stat_buf;

#if DO_UNLINK
#if DO_FCREATE
  unlink(fname);
#endif
  unlink(lname);
#endif

  /* Check for link existence first */
#if DO_LINK
  lfd = open(lname, O_RDONLY);
  if(lfd != -1)
  {
    printf("%s already exists!\n", lname);
  }
  else
  {
#if DO_FCREATE
    ffd = open(fname,  O_RDWR|O_CREAT|O_EXCL|O_TRUNC, 0666);
#endif

    ret = link(fname, lname);
    if(ret != 0)
    {
      printf("Linking %s to %s failed with error %d!\n", fname, lname, ret);
    }

#if DO_STAT
    stat(lname, &stat_buf);
#endif

#if DO_FCREATE
    write(ffd, fdata, strlen(fdata));
    close(ffd);

#if DO_WAIT
    sleep(2); //1 = 50% work, 2 = 100% work
#endif
#endif
  }
#endif

  lfd = open(fname, O_RDONLY);

#if DO_STAT
  fstat(lfd, &stat_buf);
#endif

  lseek(lfd, 0, SEEK_SET);
  
  ret = read(lfd, buf, 4096);
  close(lfd);

  printf("Read %d bytes of data.\n", ret);

#if DO_SECOND_READ
  //sleep(0.5);
  lfd = open(lname, O_RDONLY);

#if DO_STAT
  fstat(lfd, &stat_buf);
#endif

  lseek(lfd, 0, SEEK_SET);
  
  ret = read(lfd, buf, 4096);
  close(lfd);

  printf("Read %d bytes of data.\n", ret);
#endif

  return 0;
}

