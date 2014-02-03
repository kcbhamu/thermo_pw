!
! Copyright (C) 2013 Andrea Dal Corso
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
SUBROUTINE run_thermo_asyncronously(nwork, part, igeom, auxdyn)
  USE mp,              ONLY : mp_bcast
  USE mp_world,        ONLY : world_comm, nproc
  USE io_global,       ONLY : ionode, ionode_id, meta_ionode_id, stdout
  USE mp_images,       ONLY : nimage, root_image, my_image_id, & 
                              intra_image_comm
  USE mp_asyn,         ONLY : asyn_master_init_with_priority, asyn_worker_init, &
                              asyn_close, asyn_master, asyn_worker, &
                              asyn_master_work, with_asyn_images
  USE thermo_priority, ONLY : npriority, priority, max_priority
  USE thermo_mod,      ONLY : alat_geo, energy_geo
  USE thermodynamics,  ONLY : ngeo
  USE control_thermo,  ONLY : lpwscf, lbands, lphonon
  USE ener,            ONLY : etot
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(IN) :: nwork, part, igeom
  CHARACTER (LEN=256), INTENT(IN) :: auxdyn

  INTEGER :: iq, irr
  INTEGER, ALLOCATABLE :: proc_num(:)
  INTEGER :: proc_per_image, iwork, image
  LOGICAL :: all_done_asyn
  !
  IF ( nwork == 0 ) RETURN
  !
  !  Two calculations are now possible. If with_asyn_images is .TRUE. each
  !  image does a different task, and the first image is the master that 
  !  keeps into account how much work there is to do and who does what.
  !  Otherwise the works are done one after the other in the traditional
  !  fashion
  !
  with_asyn_images = ( nimage > 1 )
  IF ( with_asyn_images .AND. nwork > 1) THEN
     IF (my_image_id == root_image) THEN
  !
  !  This is the master and it has to rule all the other images
  !
        all_done_asyn=.FALSE.
        ALLOCATE(proc_num(0:nimage-1))
        proc_num(0)=0 
        proc_per_image = nproc / nimage
        DO image=1,nimage-1
           proc_num(image) = proc_num(image-1) + proc_per_image
        ENDDO
  !
  !   Set the priority of the different works
  !
        CALL initialize_thermo_master(nwork, part)
  !
  !    and initialize the asyncronous communication
  !
        IF (ionode) CALL asyn_master_init_with_priority(nimage, nwork, &
                         proc_num, npriority, priority, max_priority, world_comm)
  !
  !    enter into a loop of listening, answering, and working
  !
        iwork=1
        DO WHILE ( .NOT. all_done_asyn )
!
!  The root processor of this image acts as the master. 
!  See if some worker is ready to work and give it something
!  to do.
!
           IF (ionode) CALL asyn_master(all_done_asyn)
           CALL mp_bcast(all_done_asyn, ionode_id, intra_image_comm) 

           IF (iwork > 0) THEN
              all_done_asyn=.FALSE.
!
!          Now also the master can do something. Ask for some work.
!
              IF (ionode) CALL asyn_master_work(iwork)
              CALL mp_bcast(iwork, ionode_id, intra_image_comm) 
!
!   And do the work
!
              IF (iwork>0) THEN
                 CALL set_thermo_work_todo(iwork, part, iq, irr, igeom)
                 WRITE(stdout,'(/,2x,76("+"))')
                 IF (lpwscf(iwork)) THEN
                    WRITE(6,'(5x,"I am the master and now I do geometry", i5)') &
                                                  iwork
                 ELSE IF (lbands(iwork)) THEN
                    WRITE(6,'(5x,"I am the master and now I do the bands", i5)') 
                 ELSE IF (lphonon(iwork)) THEN
                    WRITE(stdout,'(5x,"I am the master and now I do point", i5, &
                  & " irrep", i5, " of geometry", i5 )') iq, irr, igeom
                 END IF
                 WRITE(stdout,'(2x,76("+"),/)')
                 IF (lpwscf(iwork)) THEN
                    CALL do_pwscf(.TRUE.)
                    energy_geo(iwork)=etot
                 ENDIF
                 IF (lbands(iwork)) CALL do_pwscf(.FALSE.)
                 IF (lphonon(iwork)) CALL do_phonon(auxdyn) 
              ENDIF
           ENDIF
           !
        ENDDO
        !
        DEALLOCATE(proc_num)
        IF (ionode) CALL asyn_close()
     ELSE
!
!  This is a worker and asks the master what to do.
!  First initializes the worker stuff. It declares the identity of the master 
!  and which communicator to use
!
        IF (ionode) CALL asyn_worker_init(meta_ionode_id, world_comm)
        iwork=1
        DO WHILE (iwork > 0)
!
!       The root_processor of each image asks the master for some work
!       to do and sends the info to all processors of its image
!       This is a blocking request, all the image blocks here until the
!       master answers.
!
           IF (ionode) CALL asyn_worker(iwork)
           CALL mp_bcast(iwork, root_image, intra_image_comm) 
!
!       and then do the work
!
           IF (iwork>0) THEN
              CALL set_thermo_work_todo(iwork, part, iq, irr, igeom)
              WRITE(stdout,'(/,2x,76("+"))')
              IF (lpwscf(iwork)) THEN
                 WRITE(6,'(5x,"I am image ", i5, " and now I do geometry", i5)') &
                                                 my_image_id, iwork
              ELSE IF (lbands(iwork)) THEN
                 WRITE(6,'(5x,"I am image ", i5, " and now I do bands", i5)') &
                                                 my_image_id
              ELSE IF (lphonon(iwork)) THEN
                 WRITE(stdout,'(5x,"I am image ",i5," and now I do point", i5,  &
                  & " irrep", i5, " of geometry", i5 )') my_image_id, iq, irr, &
                                                         igeom
              END IF
              WRITE(stdout,'(2x,76("+"),/)')
 
              IF (lpwscf(iwork)) THEN
                 CALL do_pwscf(.TRUE.)
                 energy_geo(iwork)=etot
              END IF
              IF (lbands(iwork)) CALL do_pwscf(.FALSE.)
              IF (lphonon(iwork)) THEN
                 CALL do_phonon(auxdyn) 
                 CALL collect_grid_files()
              END IF
           END IF
        END DO
     END IF
  ELSE
!
!  This is the standard case. Asyncronous images are not used. There is
!  only the master that does all the works one after the other.
!
     IF (my_image_id == root_image) THEN
        CALL initialize_thermo_master(nwork, part)
        DO iwork = 1, nwork
           CALL set_thermo_work_todo(iwork, part, iq, irr, igeom)
           IF (lpwscf(iwork)) THEN
              CALL do_pwscf(.TRUE.)
              energy_geo(iwork)=etot
           END IF
           IF (lbands(iwork)) CALL do_pwscf('bands')
           write(6,*) 'doing work', iwork, nwork, lphonon(iwork)
           IF (lphonon(iwork)) CALL do_phonon(auxdyn)
        END DO
     END IF
  END IF
RETURN
!
END SUBROUTINE run_thermo_asyncronously