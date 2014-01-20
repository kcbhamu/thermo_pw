!
! Copyright (C) 2013 Andrea Dal Corso
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-------------------------------------------------------------------------
PROGRAM thermo_pw
  !-----------------------------------------------------------------------
  !
  ! ... This is a driver for the calculation of thermodynamic quantities,
  ! ... using the harmonic and/or quasiharmonic approximation and the
  ! ... plane waves pseudopotential method.
  ! ... It reads the input of pwscf and an input that specifies
  ! ... which calculations to do and the parameters for these calculations.
  ! ... It checks the scratch directories to see what has been already
  ! ... calculated. The info for the quantities that have been already
  ! ... calculated is read inside the code. The others tasks are scheduled,
  ! ... their priorities determined, and distributed to the image driver.
  ! ... If there are several available images the different tasks are
  ! ... carried out in parallel. This driver can carry out a scf 
  ! ... calculation, a non scf calculation to determine the band structure,
  ! ... or a linear response calculation at a given q and for a given
  ! ... representation. Finally the root image can carry out several
  ! ... post processing tasks. The task currently implemented are:
  ! ... 
  ! ...   scf       : a single scf calculation to determine the total energy.
  ! ...   scf_bands : a band structure calculation after a scf calcul.
  ! ...   scf_ph    : a phonon at a single q after a scf run
  ! ...   scf_disp  : a phonon dispersion calculation after a scf run
  ! ...   mur_lc    : lattice constant via murnaghan equation
  ! ...   mur_lc_bands  : a band structure calculation at the minimum or the
  ! ...               murnaghan
  ! ...   mur_lc_ph : a phonon calculation at the minimum of the murmaghan
  ! ...   mur_lc_disp : a dispersion calculation at the minimum of the
  ! ...               murnaghan with possibility to compute harmonic
  ! ...               thermodynamical quantities
  ! ...   mur_lc_t  : lattice constant and bulk modulus as a function 
  ! ...               of temperature within the quasiharmonic approximation

  USE kinds,            ONLY : DP
  USE check_stop,       ONLY : check_stop_init
  USE mp_global,        ONLY : mp_startup, mp_global_end
  USE mp_images,        ONLY : nimage, nproc_image, my_image_id, root_image
  USE environment,      ONLY : environment_start, environment_end
  USE mp_world,         ONLY : world_comm
  USE mp_asyn,          ONLY : with_asyn_images
  USE control_ph,       ONLY : wai => with_asyn_images, always_run
  USE io_global,        ONLY : ionode, stdout
  USE mp,               ONLY : mp_sum
  USE control_thermo,   ONLY : lev_syn_1, lev_syn_2, lpwscf_syn_1, &
                               lbands_syn_1, lph, outdir_thermo, lq2r, &
                               lmatdyn, ldos, ltherm, flfrc, flfrq, fldos, &
                               fltherm, spin_component, flevdat, &
                               lconv_ke_test, lconv_nk_test

  USE ifc,              ONLY : freqmin, freqmax
  USE control_paths,    ONLY : nqaux, nbnd_bands
  USE control_gnuplot,  ONLY : flpsdos, flgnuplot, flpstherm, flpsdisp
  USE control_bands,    ONLY : flpband
  USE wvfct,            ONLY : nbnd
  USE lsda_mod,         ONLY : nspin
  USE thermodynamics,   ONLY : phdos_save, ngeo, ntemp
  USE phdos_module,     ONLY : destroy_phdos
  USE input_parameters, ONLY : ibrav, celldm, a, b, c, cosab, cosac, cosbc, &
                               trd_ht, rd_ht, cell_units, outdir
  USE thermo_mod,       ONLY : vmin, what, energy_geo, b0, b01, emin
  USE ph_restart,       ONLY : destroy_status_run
  USE save_ph,          ONLY : clean_input_variables
  USE output,           ONLY : fildyn
  USE io_files,         ONLY : tmp_dir, wfc_dir
  USE cell_base,        ONLY : cell_base_init
  USE fft_base,         ONLY : dfftp, dffts
  !
  IMPLICIT NONE
  !
  INTEGER :: iq, irr, ierr
  CHARACTER (LEN=9)   :: code = 'THERMO_PW'
  CHARACTER (LEN=256) :: auxdyn=' '
  CHARACTER (LEN=256) :: diraux=' '
  CHARACTER(LEN=6) :: int_to_char
  INTEGER :: part, nwork, igeom, itemp, nspin0
  LOGICAL :: all_done_asyn
  LOGICAL  :: exst, parallelfs
  CHARACTER(LEN=256) :: fildyn_thermo, flfrc_thermo, flfrq_thermo, &
                        fldos_thermo, fltherm_thermo, flpband_thermo, &
                        flpsdos_thermo, flpstherm_thermo, flgnuplot_thermo, &
                        flpsdisp_thermo
  !
  ! Initialize MPI, clocks, print initial messages
  !
  CALL mp_startup ( start_images=.true. )
  CALL environment_start ( code )
  CALL start_clock( 'PWSCF' )
  with_asyn_images=(nimage > 1)
  !
  ! ... and begin with the initialization part
  !
  CALL thermo_readin()
  !
  CALL check_stop_init()
  !
  part = 1
  !
  CALL initialize_thermo_work(nwork, part)
  !
  !  In this part the images work asyncronously. No communication is
  !  allowed except though the master-workers mechanism
  !
  CALL run_thermo_asyncronously(nwork, part, 1, auxdyn)
  !
  !  In this part all images are syncronized and can communicate their results
  !  thought the world_comm communicator
  !
  CALL mp_sum(energy_geo, world_comm)
  energy_geo=energy_geo / nproc_image
  IF (lconv_ke_test) THEN
     CALL write_e_ke()
     CALL plot_e_ke()
  ENDIF
  IF (lconv_nk_test) THEN
     CALL write_e_nk()
     CALL plot_e_nk()
  ENDIF
  IF (lev_syn_1) THEN
     CALL do_ev()
     CALL mur(vmin,b0,b01,emin)
     CALL plot_mur()
  ENDIF
  !
  CALL deallocate_asyn()
  ! 
  IF (lpwscf_syn_1) THEN
     IF (lev_syn_1) THEN
        celldm(1)=( vmin * 4.0_DP )**( 1.0_DP / 3.0_DP )
        CALL cell_base_init ( ibrav, celldm, a, b, c, cosab, cosac, cosbc, &
                         trd_ht, rd_ht, cell_units )
        dfftp%nr1=0
        dfftp%nr2=0
        dfftp%nr3=0
        dffts%nr1=0
        dffts%nr2=0
        dffts%nr3=0
     END IF

     outdir=TRIM(outdir_thermo)//'g1/'
     tmp_dir = TRIM ( outdir )
     wfc_dir = tmp_dir
     CALL check_tempdir ( tmp_dir, exst, parallelfs )

     IF (my_image_id==root_image) THEN
!
!   do the self consistent calculation at the new lattice constant
!
        CALL do_pwscf(.TRUE.)
        IF (lbands_syn_1) THEN
!
!   do the band calculation after setting the path
!
           CALL set_paths_disp()
           CALL set_k_points()
           IF (nbnd_bands > nbnd) nbnd = nbnd_bands
           CALL do_pwscf(.FALSE.)
           nspin0=nspin
           IF (nspin==4) nspin0=1
           DO spin_component = 1, nspin0
              CALL bands_sub()
              CALL plotband_sub(1,1)
           ENDDO
        ENDIF
     ENDIF
  END IF
  
  IF (what /= 'mur_lc_t') ngeo=1

  IF (lph) THEN
     !
     ! ... reads the phonon input
     !
     !
     wai=with_asyn_images
     always_run=.TRUE.
     CALL start_clock( 'PHONON' )
     DO igeom=1,ngeo
        write(6,*) '%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%'
        write(6,*) 'Computing geometry ', igeom
        write(6,*) '%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%'
        outdir=TRIM(outdir_thermo)//'g'//TRIM(int_to_char(igeom))//'/'
        !
        CALL thermo_ph_readin()
        IF (igeom==1) fildyn_thermo=TRIM(fildyn)
        IF (igeom==1) flfrc_thermo=TRIM(flfrc)
        IF (igeom==1) flfrq_thermo=TRIM(flfrq)
        IF (igeom==1) fldos_thermo=TRIM(fldos)
        IF (igeom==1) flpsdos_thermo=TRIM(flpsdos)
        IF (igeom==1) fltherm_thermo=TRIM(fltherm)
        IF (igeom==1) flpstherm_thermo=TRIM(flpstherm)
        IF (igeom==1) flpband_thermo=TRIM(flpband)
        IF (igeom==1) flgnuplot_thermo=TRIM(flgnuplot)
        IF (igeom==1) flpsdisp_thermo=TRIM(flpsdisp)

        fildyn=TRIM(fildyn_thermo)//'.g'//TRIM(int_to_char(igeom))//'.'
        flfrc=TRIM(flfrc_thermo)//'.g'//TRIM(int_to_char(igeom))
        flfrq=TRIM(flfrq_thermo)//'.g'//TRIM(int_to_char(igeom))
        fldos=TRIM(fldos_thermo)//'.g'//TRIM(int_to_char(igeom))
        flpsdos=TRIM(flpsdos_thermo)//'.g'//TRIM(int_to_char(igeom))
        fltherm=TRIM(fltherm_thermo)//'.g'//TRIM(int_to_char(igeom))
        flpstherm=TRIM(flpstherm_thermo)//'.g'//TRIM(int_to_char(igeom))
        flpband=TRIM(flpband_thermo)//'.g'//TRIM(int_to_char(igeom))
        flgnuplot=TRIM(flgnuplot_thermo)//'.g'//TRIM(int_to_char(igeom))
        flpsdisp=TRIM(flpsdisp_thermo)//'.g'//TRIM(int_to_char(igeom))

        IF (nqaux > 0) CALL set_paths_disp()
        !
        ! ... Checking the status of the calculation and if necessary initialize
        ! ... the q mesh and all the representations
        !
        CALL check_initial_status(auxdyn)

        part=2
        CALL initialize_thermo_work(nwork, part)
        !
        !  Asyncronous work starts again. No communication is
        !  allowed except though the master workers mechanism
        !
        CALL run_thermo_asyncronously(nwork, part, igeom, auxdyn)
        !  
        !   return to syncronous work. Collect the work of all images and
        !   writes the dynamical matrix
        !
        CALL collect_everything(auxdyn)
        !
        IF (lq2r) THEN
           CALL q2r_sub(auxdyn) 
!
!    compute interpolated dispersions
!
           IF (lmatdyn) THEN
              CALL matdyn_sub(.FALSE., igeom)
              CALL plotband_sub(2,igeom)
           ENDIF
!
!    computes phonon dos
!
           IF (lmatdyn.AND.ldos) THEN
              IF (.NOT.ALLOCATED(phdos_save)) ALLOCATE(phdos_save(ngeo))
              CALL matdyn_sub(.TRUE.,igeom)
              CALL simple_plot('_dos', fldos, flpsdos, 'frequency (cm^{-1})', &
                       'DOS (states / cm^{-1} / cell)', 'red', freqmin, freqmax, &
                            0.0_DP, 0.0_DP)
           ENDIF
!
!    computes the thermodynamical properties
!
           IF (ldos.AND.ltherm) THEN
              CALL write_thermo(igeom)
              CALL plot_thermo(igeom)
           ENDIF
!
!     Per ogni temperatura bisogna settare l'input di ev.x e chiamare ev.x
!     poi raccogliere a e B per ogni T e scriverli in output
!
        ENDIF
        CALL deallocate_asyn()
        CALL clean_pw(.TRUE.)
        CALL close_phq(.FALSE.)
        CALL clean_input_variables()
        CALL destroy_status_run()
        CALL deallocate_part()
     ENDDO
     flgnuplot=TRIM(flgnuplot_thermo)

     IF (lev_syn_2) THEN
        diraux='evdir'
        CALL check_tempdir ( diraux, exst, parallelfs )
        flevdat=TRIM(diraux)//'/'//TRIM(flevdat)
        DO itemp = 1, ntemp
           IF (lev_syn_2) CALL do_ev_t(itemp)
        ENDDO
        CALL write_anharmonic()
        CALL plot_anhar() 
     ENDIF

     IF (lmatdyn.AND.ldos) THEN
        DO igeom=1,ngeo
           CALL destroy_phdos(phdos_save(igeom))
        ENDDO
        DEALLOCATE(phdos_save)
     ENDIF
  ENDIF
  !
  CALL deallocate_thermo()
  !
  CALL stop_clock( 'PWSCF' )
  !
  CALL environment_end( 'THERMO_PW' )
  !
  CALL mp_global_end ()
  !
  STOP
  !
END PROGRAM thermo_pw
