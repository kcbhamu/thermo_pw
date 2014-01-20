!
! Copyright (C) 2014 Andrea Dal Corso 
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
SUBROUTINE plot_anhar()
!
!  This is a driver to plot the quantities written inside flanhar
!  
!
USE kinds,           ONLY : DP
USE control_gnuplot, ONLY : flgnuplot, flpsanhar
USE gnuplot,         ONLY : gnuplot_start, gnuplot_end,  &
                            gnuplot_write_header,        &
                            gnuplot_ylabel,              &
                            gnuplot_xlabel,              &
                            gnuplot_write_file_mul_data, &
                            gnuplot_write_vertical_line, &
                            gnuplot_set_fact
USE control_thermo,  ONLY : flanhar
USE thermodynamics,  ONLY : tmin, tmax
USE constants,       ONLY : ry_kbar
USE mp_images,       ONLY : my_image_id, root_image

IMPLICIT NONE

CHARACTER(LEN=256) :: filename
CHARACTER(LEN=6), EXTERNAL :: int_to_char

IF ( my_image_id /= root_image ) RETURN

filename=TRIM(flgnuplot)//'_anhar'
CALL gnuplot_start(filename)

filename=TRIM(flpsanhar)
IF (tmin /= 1.0_DP) THEN
   CALL gnuplot_write_header(filename, tmin, tmax, 0.0_DP, 0.0_DP ) 
ELSE
   CALL gnuplot_write_header(filename, 0.0_DP, tmax, 0.0_DP, 0.0_DP ) 
ENDIF

CALL gnuplot_xlabel('T (K)') 
CALL gnuplot_ylabel('Volume ((a.u.)^3)') 
CALL gnuplot_write_file_mul_data(flanhar,1,2,'red',.TRUE.,.TRUE.)

CALL gnuplot_ylabel('Thermal expansion ({/Symbol b} x 10^{6})') 
CALL gnuplot_write_file_mul_data(flanhar,1,3,'blue',.TRUE.,.TRUE.)

CALL gnuplot_ylabel('Bulk modulus (kbar)') 
CALL gnuplot_write_file_mul_data(flanhar,1,4,'red',.TRUE.,.TRUE.)

CALL gnuplot_set_fact(1313313.0_DP)
CALL gnuplot_ylabel('Heat capacity C_v (J / K / N / mol)') 
CALL gnuplot_write_file_mul_data(flanhar,1,5,'blue',.TRUE.,.TRUE.)


filename=TRIM(flanhar)//'.aux'
CALL gnuplot_ylabel('Heat capacity C_p (J / K / N / mol)') 
CALL gnuplot_write_file_mul_data(filename,1,3,'red',.TRUE.,.TRUE.)

CALL gnuplot_ylabel('C_p - C_v (J / K / N / mol)') 
CALL gnuplot_write_file_mul_data(filename,1,4,'blue',.TRUE.,.TRUE.)

CALL gnuplot_set_fact(1.0_DP)
CALL gnuplot_ylabel('{/Symbol g}') 
CALL gnuplot_write_file_mul_data(filename,1,2,'red',.TRUE.,.TRUE.)

CALL gnuplot_ylabel('B_S - B_T (kbar)') 
CALL gnuplot_write_file_mul_data(filename,1,5,'blue',.TRUE.,.TRUE.)

CALL gnuplot_end()

RETURN
END SUBROUTINE plot_anhar

