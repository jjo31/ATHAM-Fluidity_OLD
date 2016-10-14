!     path:      $Source: /storm/rc1/cvsroot/rc/rrtmg_lw/src/rrtmg_lw_rad.nomcica.f90,v $
!     author:    $Author: mike $
!     revision:  $Revision: 1.10 $
!     created:   $Date: 2009/05/22 21:04:31 $
!

       module rrtmg_lw_rad

!  --------------------------------------------------------------------------
! |                                                                          |
! |  Copyright 2002-2009, Atmospheric & Environmental Research, Inc. (AER).  |
! |  This software may be used, copied, or redistributed as long as it is    |
! |  not sold and this copyright notice is reproduced on each copy made.     |
! |  This model is provided as is without any express or implied warranties. |
! |                       (http://www.rtweb.aer.com/)                        |
! |                                                                          |
!  --------------------------------------------------------------------------
!
! ****************************************************************************
! *                                                                          *
! *                              RRTMG_LW                                    *
! *                                                                          *
! *                                                                          *
! *                                                                          *
! *                   a rapid radiative transfer model                       *
! *                       for the longwave region                            * 
! *             for application to general circulation models                *
! *                                                                          *
! *                                                                          *
! *            Atmospheric and Environmental Research, Inc.                  *
! *                        131 Hartwell Avenue                               *
! *                        Lexington, MA 02421                               *
! *                                                                          *
! *                                                                          *
! *                           Eli J. Mlawer                                  *
! *                        Jennifer S. Delamere                              *
! *                         Michael J. Iacono                                *
! *                         Shepard A. Clough                                *
! *                                                                          *
! *                                                                          *
! *                                                                          *
! *                                                                          *
! *                                                                          *
! *                                                                          *
! *                       email:  emlawer@aer.com                            *
! *                       email:  jdelamer@aer.com                           *
! *                       email:  miacono@aer.com                            *
! *                                                                          *
! *        The authors wish to acknowledge the contributions of the          *
! *        following people:  Steven J. Taubman, Karen Cady-Pereira,         *
! *        Patrick D. Brown, Ronald E. Farren, Luke Chen, Robert Bergstrom.  *
! *                                                                          *
! ****************************************************************************

!----------------------------------------------------------------------------!
! modified by Tobias Gerken tg303@cam.ac.uk (Nov 2009)                       !
! routine was changed to handle 3D arrays due to perfromance improvement     !
! this means (ncol,nlay) --> (nx,ny,nz)                                      !
! additionally for non some atmospheric constitutents a single concentration !
! is assumed --> well mixed atmoshpere                                       !
! ozone and water vapor input were changed to mass mixing ratio              !
! also a klow was added in order to treat topography                         !
!----------------------------------------------------------------------------! 

! -------- Modules --------
      use parkind, only : im => kind_im, rb => kind_rb
      use rrlw_vsn
      use rrtmg_lw_cldprop, only: cldprop
! *** Move the required call to rrtmg_lw_ini below and the following 
! use association to the GCM initialization area ***
!      use rrtmg_lw_init, only: rrtmg_lw_ini
      use rrtmg_lw_rtrn, only: rtrn
      use rrtmg_lw_rtrnmr, only: rtrnmr
      use rrtmg_lw_setcoef, only: setcoef
      use rrtmg_lw_taumol, only: taumol

      implicit none
 
      private

! public interfaces/functions/subroutines
      public :: rrtmg_lw, inatm

!------------------------------------------------------------------
      contains
!------------------------------------------------------------------

!------------------------------------------------------------------
! Public subroutines
!------------------------------------------------------------------

      subroutine rrtmg_lw &
            (nx, nxl, nxr, ny, nyv, nyh, nlay    ,icld    , &
             play    ,plev    ,tlay    ,tlev    ,tsfc    , &
             h2ommr  ,o3mmr   ,co2vmr  ,ch4vmr  ,n2ovmr  ,o2vmr, & !note h2ommr
             cfc11vmr,cfc12vmr,cfc22vmr,ccl4vmr ,emis    ,ifeld, & ! o3mmr
             inflglw ,iceflglw,liqflglw,cldfr   , &
             cicewp  ,cliqwp  ,reice   ,reliq   , &
             tauaer  , &
             uflx    ,dflx    ,hr      ,uflxc   ,dflxc,  hrc, rad_down, & !optional arguments:
             o2vmr_a, cfc11vmr_a, cfc12vmr_a, cfc22vmr_a, ccl4vmr_a)

! -------- Description --------

! This program is the driver subroutine for RRTMG_LW, the AER LW radiation 
! model for application to GCMs, that has been adapted from RRTM_LW for
! improved efficiency.
!
! NOTE: The call to RRTMG_LW_INI should be moved to the GCM initialization
!  area, since this has to be called only once. 
!
! This routine:
!    a) calls INATM to read in the atmospheric profile from GCM;
!       all layering in RRTMG is ordered from surface to toa. 
!    b) calls CLDPROP to set cloud optical depth based on input
!       cloud properties
!    c) calls SETCOEF to calculate various quantities needed for 
!       the radiative transfer algorithm
!    d) calls TAUMOL to calculate gaseous optical depths for each 
!       of the 16 spectral bands
!    e) calls RTRNMR (for both clear and cloudy profiles) to perform the
!       radiative transfer calculation with a maximum-random cloud
!       overlap method, or calls RTRN to use random cloud overlap.
!    f) passes the necessary fluxes and cooling rates back to GCM
!
! Two modes of operation are possible:
!     The mode is chosen by using either rrtmg_lw.nomcica.f90 (to not use
!     McICA) or rrtmg_lw.f90 (to use McICA) to interface with a GCM. 
!
!    1) Standard, single forward model calculation (imca = 0)
!    2) Monte Carlo Independent Column Approximation (McICA, Pincus et al., 
!       JC, 2003) method is applied to the forward model calculation (imca = 1)
!
! Two methods of cloud property input are possible:
!     Cloud properties can be input in one of two ways (controlled by input 
!     flags inflglw, iceflglw, and liqflglw; see text file rrtmg_lw_instructions
!     and subroutine rrtmg_lw_cldprop.f90 for further details):
!
!    1) Input cloud fraction and cloud optical depth directly (inflglw = 0)
!    2) Input cloud fraction and cloud physical properties (inflglw = 1 or 2);  
!       cloud optical properties are calculated by cldprop or cldprmc based
!       on input settings of iceflglw and liqflglw.  Ice particle size provided
!       must be appropriately defined for the ice parameterization selected. 
!
! One method of aerosol property input is possible:
!     Aerosol properties can be input in only one way (controlled by input 
!     flag iaer; see text file rrtmg_lw_instructions for further details):
!
!    1) Input aerosol optical depth directly by layer and spectral band (iaer=10);
!       band average optical depth at the mid-point of each spectral band.
!       RRTMG_LW currently treats only aerosol absorption;
!       scattering capability is not presently available.
!
!
! ------- Modifications -------
!
! This version of RRTMG_LW has been modified from RRTM_LW to use a reduced 
! set of g-points for application to GCMs.  
!
!-- Original version (derived from RRTM_LW), reduction of g-points, other
!   revisions for use with GCMs.  
!     1999: M. J. Iacono, AER, Inc.
!-- Adapted for use with NCAR/CAM.
!     May 2004: M. J. Iacono, AER, Inc.
!-- Conversion to F90 formatting for consistency with rrtmg_sw.
!     Feb 2007: M. J. Iacono, AER, Inc.
!-- Modifications to formatting to use assumed-shape arrays.
!     Aug 2007: M. J. Iacono, AER, Inc.
!-- Modified to add longwave aerosol absorption.
!     Apr 2008: M. J. Iacono, AER, Inc.

! --------- Modules ----------

      use parrrtm, only : nbndlw, ngptlw, maxxsec, mxmol
      use rrlw_con, only: fluxfac, heatfac, oneminus, pi
      use rrlw_wvn, only: ng, ngb, nspa, nspb, wavenum1, wavenum2, delwave
! ------- Declarations -------

! ----- Input -----
! Note: All volume mixing ratios are in dimensionless units of mole fraction obtained
! by scaling mass mixing ratio (g/g) with the appropriate molecular weights (g/mol) 

      integer(kind=im), intent(in) :: ifeld(:,:)     ! (MA)
      integer(kind=im), intent(in) :: nxr, nxl, nyv, nyh, nx, ny !(MA)
 !     integer(kind=im), intent(in) :: ncol            ! Number of horizontal columns
      integer(kind=im), intent(in) :: nlay            ! Number of model layers
      integer(kind=im), intent(inout) :: icld         ! Cloud overlap method
                                                      !    0: Clear only
                                                      !    1: Random
                                                      !    2: Maximum/random
                                                      !    3: Maximum

      real(kind=rb), intent(in) :: play(:,:,:)          ! Layer pressures (hPa, mb)
                                                      !    Dimensions: (ncol,ny,nlay)
      real(kind=rb), intent(in) :: plev(:,:,:)          ! Interface pressures (hPa, mb)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(in) :: tlay(:,:,:)          ! Layer temperatures (K)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: tlev(:,:,:)          ! Interface temperatures (K)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(in) :: tsfc(:,:)            ! Surface temperature (K)
                                                      !    Dimensions: (ncol)
      real(kind=rb), intent(in) :: h2ommr(:,:,:)        ! H2O (volume) mass mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: o3mmr(:,:,:)         ! O3 (volume) mass mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: co2vmr(:,:,:)        ! CO2 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: ch4vmr(:,:,:)        ! Methane volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: n2ovmr(:,:,:)        ! Nitrous oxide volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: o2vmr             ! Oxygen volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc11vmr           ! CFC11 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc12vmr           ! CFC12 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc22vmr           ! CFC22 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: ccl4vmr            ! CCL4 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: emis(:,:,:)          ! Surface emissivity
                                                      !    Dimensions: (ncol,x,nbndlw)

      integer(kind=im), intent(in) :: inflglw         ! Flag for cloud optical properties
      integer(kind=im), intent(in) :: iceflglw        ! Flag for ice particle specification
      integer(kind=im), intent(in) :: liqflglw        ! Flag for liquid droplet specification

      real(kind=rb), intent(in) :: cldfr(:,:,:)         ! Cloud fraction
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cicewp(:,:,:)        ! Cloud ice water path (g/m2)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cliqwp(:,:,:)        ! Cloud liquid water path (g/m2)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: reice(:,:,:)         ! Cloud ice particle effective size (microns)
                                                      !    Dimensions: (ncol,nlay)
                                                      ! specific definition of reice depends on setting of iceflglw:
                                                      ! iceflglw = 0: ice effective radius, r_ec, (Ebert and Curry, 1992),
                                                      !               r_ec must be >= 10.0 microns
                                                      ! iceflglw = 1: ice effective radius, r_ec, (Ebert and Curry, 1992),
                                                      !               r_ec range is limited to 13.0 to 130.0 microns
                                                      ! iceflglw = 2: ice effective radius, r_k, (Key, Streamer Ref. Manual, 1996)
                                                      !               r_k range is limited to 5.0 to 131.0 microns
                                                      ! iceflglw = 3: generalized effective size, dge, (Fu, 1996),
                                                      !               dge range is limited to 5.0 to 140.0 microns
                                                      !               [dge = 1.0315 * r_ec]
      real(kind=rb), intent(in) :: reliq(:,:,:)         ! Cloud water drop effective radius (microns)
                                                      !    Dimensions: (ncol,nlay)
    !  real(kind=rb), intent(in) :: taucld(:,:,:)      ! In-cloud optical depth
                                                      !    Dimensions: (nbndlw,ncol,nlay)
!      real(kind=rb), intent(in) :: ssacld(:,:,:)     ! In-cloud single scattering albedo
                                                      !    Dimensions: (nbndlw,ncol,nlay)
                                                      !   for future expansion 
                                                      !   (lw scattering not yet available)
!      real(kind=rb), intent(in) :: asmcld(:,:,:)     ! In-cloud asymmetry parameter
                                                      !    Dimensions: (nbndlw,ncol,nlay)
                                                      !   for future expansion 
                                                      !   (lw scattering not yet available)
      real(kind=rb), intent(in) :: tauaer(:,:,:,:)      ! aerosol optical depth
                                                      !    Dimensions: (ncol,nlay,nbndlw)
!      real(kind=rb), intent(in) :: ssaaer(:,:,:)     ! aerosol single scattering albedo
                                                      !    Dimensions: (ncol,nlay,nbndlw)
                                                      !   for future expansion 
                                                      !   (lw aerosols/scattering not yet available)
!      real(kind=rb), intent(in) :: asmaer(:,:,:)     ! aerosol asymmetry parameter
                                                      !    Dimensions: (ncol,nlay,nbndlw)
                                                      !   for future expansion 
                                                      !   (lw aerosols/scattering not yet available)

      REAL(kind=rb), intent(in) :: rad_down(:)

! ----- Output -----

      real(kind=rb), intent(out) :: uflx(:,:,:)         ! Total sky longwave upward flux (W/m2)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(out) :: dflx(:,:,:)         ! Total sky longwave downward flux (W/m2)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(out) :: hr(:,:,:)           ! Total sky longwave radiative heating rate (K/d)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(out) :: uflxc(:,:,:)        ! Clear sky longwave upward flux (W/m2)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(out) :: dflxc(:,:,:)        ! Clear sky longwave downward flux (W/m2)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(out) :: hrc(:,:,:)          ! Clear sky longwave radiative heating rate (K/d)
                                                      !    Dimensions: (ncol,nlay)
! optional array arguments for well mixed gasses
      
      real(kind=rb), intent(in), optional :: o2vmr_a(:,:,:)   ! Oxygen volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc11vmr_a(:,:,:) ! CFC11 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc12vmr_a(:,:,:) ! CFC12 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc22vmr_a(:,:,:) ! CFC22 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: ccl4vmr_a(:,:,:) ! CCL4 volume mixing ratio


! ----- Local -----

! Control
      integer(kind=im) :: nlayers             ! total number of layers
      integer(kind=im) :: ncol                 
      integer(kind=im) :: istart              ! beginning band of calculation
      integer(kind=im) :: iend                ! ending band of calculation
      integer(kind=im) :: iout                ! output option flag (inactive)
      integer(kind=im) :: iaer                ! aerosol option flag
      integer(kind=im) :: iplon, j            ! column loop indices
      integer(kind=im) :: imca                ! flag for mcica [0=off, 1=on]
      integer(kind=im) :: k                   ! layer loop index
      integer(kind=im) :: ig                  ! g-point loop index
      integer(kind=im) :: klow                ! first active k 
      logical          :: array_in

! Atmosphere
      REAL(kind=rb) :: pavel(nlay+1)          ! layer pressures (mb) 
      REAL(kind=rb) :: tavel(nlay+1)          ! layer temperatures (K)
      REAL(kind=rb) :: pz(0:nlay+1)           ! level (interface) pressures (hPa, mb)
      REAL(kind=rb) :: tz(0:nlay+1)           ! level (interface) temperatures (K)
      real(kind=rb) :: tbound                 ! surface temperature (K)
      REAL(kind=rb) :: coldry(nlay+1)         ! dry air column density (mol/cm2)
      REAL(kind=rb) :: wbrodl(nlay+1)         ! broadening gas column density (mol/cm2)
      REAL(kind=rb) :: wkl(mxmol,nlay+1)      ! molecular amounts (mol/cm-2)
      REAL(kind=rb) :: wx(maxxsec,nlay+1)     ! cross-section amounts (mol/cm-2)
      real(kind=rb) :: pwvcm                  ! precipitable water vapor (cm)
      real(kind=rb) :: semiss(nbndlw)         ! lw surface emissivity
      REAL(kind=rb) :: fracs(nlay+1,ngptlw)   !
      REAL(kind=rb) :: taug(nlay+1,ngptlw)    ! gaseous optical depth 
      REAL(kind=rb) :: taut(nlay+1,ngptlw)    ! gaseous + aerosol optical depths

      REAL(kind=rb) :: taua(nlay+1,nbndlw)    ! aerosol optical depth
!      real(kind=rb) :: ssaa(nlay+1,nbndlw)   ! aerosol single scattering albedo
                                              !   for future expansion 
                                              !   (lw aerosols/scattering not yet available)
!      real(kind=rb) :: asma(nlay+1,nbndlw)   ! aerosol asymmetry parameter
                                              !   for future expansion 
                                              !   (lw aerosols/scattering not yet available)


! Atmosphere - setcoef
      integer(kind=im) :: laytrop             ! tropopause layer index
      INTEGER(kind=im) :: jp(nlay+1)          ! lookup table index 
      INTEGER(kind=im) :: jt(nlay+1)          ! lookup table index 
      INTEGER(kind=im) :: jt1(nlay+1)         ! lookup table index 
      REAL(kind=rb) :: planklay(nlay+1,nbndlw)! 
      REAL(kind=rb) :: planklev(0:nlay+1,nbndlw)! 
      real(kind=rb) :: plankbnd(nbndlw)       ! 

      REAL(kind=rb) :: colh2o(nlay+1)         ! column amount (h2o)
      REAL(kind=rb) :: colco2(nlay+1)         ! column amount (co2)
      REAL(kind=rb) :: colo3(nlay+1)          ! column amount (o3)
      REAL(kind=rb) :: coln2o(nlay+1)         ! column amount (n2o)
      REAL(kind=rb) :: colco(nlay+1)          ! column amount (co)
      REAL(kind=rb) :: colch4(nlay+1)         ! column amount (ch4)
      REAL(kind=rb) :: colo2(nlay+1)          ! column amount (o2)
      REAL(kind=rb) :: colbrd(nlay+1)         ! column amount (broadening gases)

      INTEGER(kind=im) :: indself(nlay+1)
      INTEGER(kind=im) :: indfor(nlay+1)
      REAL(kind=rb) :: selffac(nlay+1)
      REAL(kind=rb) :: selffrac(nlay+1)
      REAL(kind=rb) :: forfac(nlay+1)
      REAL(kind=rb) :: forfrac(nlay+1)

      INTEGER(kind=im) :: indminor(nlay+1)
      REAL(kind=rb) :: minorfrac(nlay+1)
      REAL(kind=rb) :: scaleminor(nlay+1)
      REAL(kind=rb) :: scaleminorn2(nlay+1)

      real(kind=rb) :: &                      !
                         fac00(nlay+1), fac01(nlay+1), &
                         fac10(nlay+1), fac11(nlay+1) 
      real(kind=rb) :: &                      !
                         rat_h2oco2(nlay+1),rat_h2oco2_1(nlay+1), &
                         rat_h2oo3(nlay+1),rat_h2oo3_1(nlay+1), &
                         rat_h2on2o(nlay+1),rat_h2on2o_1(nlay+1), &
                         rat_h2och4(nlay+1),rat_h2och4_1(nlay+1), &
                         rat_n2oco2(nlay+1),rat_n2oco2_1(nlay+1), &
                         rat_o3co2(nlay+1),rat_o3co2_1(nlay+1)

! Atmosphere/clouds - cldprop
      integer(kind=im) :: ncbands             ! number of cloud spectral bands
      integer(kind=im) :: inflag              ! flag for cloud property method
      integer(kind=im) :: iceflag             ! flag for ice cloud properties
      integer(kind=im) :: liqflag             ! flag for liquid cloud properties

      REAL(kind=rb) :: cldfrac(nlay+1)        ! layer cloud fraction
      REAL(kind=rb) :: tauc(nbndlw,nlay+1)    ! in-cloud optical depth
!      real(kind=rb) :: ssac(nbndlw,nlay+1)   ! in-cloud single scattering albedo
                                              !   for future expansion 
                                              !   (lw scattering not yet available)
!      real(kind=rb) :: asmc(nbndlw,nlay+1)   ! in-cloud asymmetry parameter
                                              !   for future expansion 
                                              !   (lw scattering not yet available)
      real(kind=rb) :: ciwp(nlay+1)           ! cloud ice water path
      real(kind=rb) :: clwp(nlay+1)           ! cloud liquid water path
      real(kind=rb) :: rel(nlay+1)            ! cloud liquid particle effective radius (microns)
      real(kind=rb) :: rei(nlay+1)            ! cloud ice particle effective size (microns)
      REAL(kind=rb) :: taucloud(nlay+1,nbndlw)! layer in-cloud optical depth

! Output
      REAL(kind=rb) :: totuflux(0:nlay+1)     ! upward longwave flux (w/m2)
      REAL(kind=rb) :: totdflux(0:nlay+1)     ! downward longwave flux (w/m2)
      REAL(kind=rb) :: fnet(0:nlay+1)         ! net longwave flux (w/m2)
      REAL(kind=rb) :: htr(0:nlay+1)          ! longwave heating rate (k/day)
      REAL(kind=rb) :: totuclfl(0:nlay+1)     ! clear sky upward longwave flux (w/m2)
      REAL(kind=rb) :: totdclfl(0:nlay+1)     ! clear sky downward longwave flux (w/m2)
      REAL(kind=rb) :: fnetc(0:nlay+1)        ! clear sky net longwave flux (w/m2)
      REAL(kind=rb) :: htrc(0:nlay+1)         ! clear sky longwave heating rate (k/day)

      real(kind=rb) :: taucld(nbndlw,nx,ny,nlay)

      taucld = 0._rb


! Initializations

      oneminus = 1._rb - 1.e-6_rb
      pi = 2._rb*ASIN(1._rb)
      fluxfac = pi * 2.e4_rb                  ! orig:   fluxfac = pi * 2.d4  
      istart = 1
      iend = 16
      iout = 0
      ncol = nxr-nxl+1

! Set imca to select calculation type:
!  imca = 0, use standard forward model calculation
!  imca = 1, use McICA for Monte Carlo treatment of sub-grid cloud variability

! *** This version does not use McICA (imca = 0) ***

! Set default icld to select of clear or cloud calculation and cloud overlap method  
! icld = 0, clear only
! icld = 1, with clouds using random cloud overlap
! icld = 2, with clouds using maximum/random cloud overlap
! icld = 3, with clouds using maximum cloud overlap (McICA only)
      if (icld.lt.0.or.icld.gt.3) icld = 2

! Set iaer to select aerosol option
! iaer = 0, no aerosols
! icld = 10, input total aerosol optical depth (tauaer) directly
      iaer = 10

! Call model and data initialization, compute lookup tables, perform
! reduction of g-points from 256 to 140 for input absorption coefficient 
! data and other arrays.
!
! In a GCM this call should be placed in the model initialization
! area, since this has to be called only once.  
!      call rrtmg_lw_ini(cpdair)
      
!  This is to determine wheter inatm is called with array arguments
      array_in = .false.
      if (present(o2vmr_a) .and. present(cfc11vmr_a) .and. present(cfc12vmr_a) &
           .and. present(cfc22vmr_a) .and. present(ccl4vmr_a)) array_in = .true.


              uflx  = 0._rb
              dflx  = 0._rb
              uflxc = 0._rb
              dflxc = 0._rb
              hr    = 0._rb
              hrc   = 0._rb

!  This is the main longitude/column loop within RRTMG.
      do iplon = nxl, nxr  ! (MA)
         
         do j = nyv, nyh   ! (MA)
            klow = ifeld (iplon,j)
         
!  Prepare atmospheric profile from GCM for use in RRTMG, and define
!  other input parameters.  
!  when gaseous arrays are present inatm is called with the optional 
!  array arguments

      IF (SUM(rad_down) .gT. 1.0e-10_rb) THEN
         if (array_in) then
         call inatm_radin (iplon, j, nlay, icld, iaer, &
              play, plev, tlay, tlev, tsfc, h2ommr, &
              o3mmr, co2vmr, ch4vmr, n2ovmr, o2vmr, cfc11vmr, cfc12vmr, &
              cfc22vmr, ccl4vmr, emis, inflglw, iceflglw, liqflglw, &
              cldfr, taucld, cicewp, cliqwp, reice, reliq, tauaer, &
              nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
              wkl, wbrodl, wx, pwvcm, inflag, iceflag, liqflag, &
              cldfrac, tauc, ciwp, clwp, rei, rel, taua, klow, array_in,   &
              o2vmr_a, cfc11vmr_a, cfc12vmr_a, cfc22vmr_a, ccl4vmr_a)
         else
         call inatm_radin (iplon, j, nlay, icld, iaer, &
              play, plev, tlay, tlev, tsfc, h2ommr, &
              o3mmr, co2vmr, ch4vmr, n2ovmr, o2vmr, cfc11vmr, cfc12vmr, &
              cfc22vmr, ccl4vmr, emis, inflglw, iceflglw, liqflglw, &
              cldfr, taucld, cicewp, cliqwp, reice, reliq, tauaer, &
              nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
              wkl, wbrodl, wx, pwvcm, inflag, iceflag, liqflag, &
              cldfrac, tauc, ciwp, clwp, rei, rel, taua, klow, array_in)
         end if
      ELSE
         if (array_in) then
         call inatm (iplon, j, nlay, icld, iaer, &
              play, plev, tlay, tlev, tsfc, h2ommr, &
              o3mmr, co2vmr, ch4vmr, n2ovmr, o2vmr, cfc11vmr, cfc12vmr, &
              cfc22vmr, ccl4vmr, emis, inflglw, iceflglw, liqflglw, &
              cldfr, taucld, cicewp, cliqwp, reice, reliq, tauaer, &
              nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
              wkl, wbrodl, wx, pwvcm, inflag, iceflag, liqflag, &
              cldfrac, tauc, ciwp, clwp, rei, rel, taua, klow, array_in,   &
              o2vmr_a, cfc11vmr_a, cfc12vmr_a, cfc22vmr_a, ccl4vmr_a)
         else
         call inatm (iplon, j, nlay, icld, iaer, &
              play, plev, tlay, tlev, tsfc, h2ommr, &
              o3mmr, co2vmr, ch4vmr, n2ovmr, o2vmr, cfc11vmr, cfc12vmr, &
              cfc22vmr, ccl4vmr, emis, inflglw, iceflglw, liqflglw, &
              cldfr, taucld, cicewp, cliqwp, reice, reliq, tauaer, &
              nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
              wkl, wbrodl, wx, pwvcm, inflag, iceflag, liqflag, &
              cldfrac, tauc, ciwp, clwp, rei, rel, taua, klow, array_in)
         end if
      END IF

!  For cloudy atmosphere, use cldprop to set cloud optical properties based on
!  input cloud physical properties.  Select method based on choices described
!  in cldprop.  Cloud fraction, water path, liquid droplet and ice particle
!  effective radius must be passed into cldprop.  Cloud fraction and cloud
!  optical depth are transferred to rrtmg_lw arrays in cldprop.  

         call cldprop(nlayers, inflag, iceflag, liqflag, cldfrac, tauc, &
                      ciwp, clwp, rei, rel, ncbands, taucloud)

! Calculate information needed by the radiative transfer routine
! that is specific to this atmosphere, especially some of the 
! coefficients and indices needed to compute the optical depths
! by interpolating data from stored reference atmospheres. 

         call setcoef(nlayers, istart, pavel, tavel, tz, tbound, semiss, &
                      coldry, wkl, wbrodl, &
                      laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                      colh2o, colco2, colo3, coln2o, colco, colch4, colo2, &
                      colbrd, fac00, fac01, fac10, fac11, &
                      rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                      rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                      rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                      selffac, selffrac, indself, forfac, forfrac, indfor, &
                      minorfrac, scaleminor, scaleminorn2, indminor)

!  Calculate the gaseous optical depths and Planck fractions for 
!  each longwave spectral band.

         call taumol(nlayers, pavel, wx, coldry, &
                     laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                     colh2o, colco2, colo3, coln2o, colco, colch4, colo2, &
                     colbrd, fac00, fac01, fac10, fac11, &
                     rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                     rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                     rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                     selffac, selffrac, indself, forfac, forfrac, indfor, &
                     minorfrac, scaleminor, scaleminorn2, indminor, &
                     fracs, taug)

! Combine gaseous and aerosol optical depths, if aerosol active
         if (iaer .eq. 0) then
            do k = 1, nlayers   
               do ig = 1, ngptlw
                  taut(k,ig) = taug(k,ig)
               enddo
            enddo
         elseif (iaer .eq. 10) then
             do k = 1, nlayers 
               do ig = 1, ngptlw
                  taut(k,ig) = taug(k,ig) + taua(k,ngb(ig))
               enddo
            enddo
         endif

! Call the radiative transfer routine.
! Either routine can be called to do clear sky calculation.  If clouds
! are present, then select routine based on cloud overlap assumption
! to be used.  Clear sky calculation is done simultaneously.

        if (icld .eq. 1) then
           call rtrn(nlayers, istart, iend, iout, pz, semiss, ncbands, &
                  cldfrac, taucloud, planklay, planklev, plankbnd, &
                  pwvcm, fracs, taut, &
                  totuflux, totdflux, fnet, htr, &
                  totuclfl, totdclfl, fnetc, htrc, rad_down) 
        else
           call rtrnmr(nlayers, istart, iend, iout, pz, semiss, ncbands, &
                  cldfrac, taucloud, planklay, planklev, plankbnd, &
                  pwvcm, fracs, taut, &
                  totuflux, totdflux, fnet, htr, &
                  totuclfl, totdclfl, fnetc, htrc, rad_down) 
        endif

!  Transfer up and down fluxes and heating rate to output arrays.
!  Vertical indexing goes from bottom to top; reverse here for GCM if necessary.


           DO k = 0, nlay-klow
              uflx(iplon,j,k+klow-1) = totuflux(k)
              dflx(iplon,j,k+klow-1) = totdflux(k)
              uflxc(iplon,j,k+klow-1) = totuclfl(k)
              dflxc(iplon,j,k+klow-1) = totdclfl(k)
           enddo
           DO k = 0, nlay-klow+1
              hr(iplon,j,k+klow-1) = htr(k)
              hrc(iplon,j,k+klow-1) = htrc(k)
           enddo

      enddo
   enddo
      end subroutine rrtmg_lw

!***************************************************************************
      SUBROUTINE inatm_radin (iplon, j, nlay, icld, iaer, &
              play, plev, tlay, tlev, tsfc, h2ommr, &
              o3mmr, co2vmr, ch4vmr, n2ovmr, o2vmr, cfc11vmr, cfc12vmr, &
              cfc22vmr, ccl4vmr, emis, inflglw, iceflglw, liqflglw, &
              cldfr, taucld, cicewp, cliqwp, reice, reliq, tauaer, &
              nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
              wkl, wbrodl, wx, pwvcm, inflag, iceflag, liqflag, &
              cldfrac, tauc, ciwp, clwp, rei, rel, taua, klow, array_in, &
              o2vmr_a, cfc11vmr_a, cfc12vmr_a, cfc22vmr_a, ccl4vmr_a)
!***************************************************************************
!
!  Input atmospheric profile from GCM, and prepare it for use in RRTMG_LW.
!  Set other RRTMG_LW input parameters.  
!
!***************************************************************************

! --------- Modules ----------

      use parrrtm, only : nbndlw, ngptlw, nmol, maxxsec, mxmol
      use rrlw_con, only: fluxfac, heatfac, oneminus, pi, grav, avogad
      use rrlw_wvn, only: ng, nspa, nspb, wavenum1, wavenum2, delwave, ixindx

! ------- Declarations -------

! ----- Input -----
! Note: All volume mixing ratios are in dimensionless units of mole fraction obtained
! by scaling mass mixing ratio (g/g) with the appropriate molecular weights (g/mol) 

      integer(kind=im), intent(in) :: klow            ! first active k 
      integer(kind=im), intent(in) :: iplon, j        ! column loop indeces
      integer(kind=im), intent(in) :: nlay            ! Number of model layers
      integer(kind=im), intent(in) :: icld            ! clear/cloud and cloud overlap flag
      integer(kind=im), intent(in) :: iaer            ! aerosol option flag

      real(kind=rb), intent(in) :: play(:,:,:)          ! Layer pressures (hPa, mb)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: plev(:,:,:)          ! Interface pressures (hPa, mb)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(in) :: tlay(:,:,:)          ! Layer temperatures (K)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: tlev(:,:,:)          ! Interface temperatures (K)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(in) :: tsfc(:,:)            ! Surface temperature (K)
                                                      !    Dimensions: (ncol)
      real(kind=rb), intent(in) :: h2ommr(:,:,:)        ! H2O (volume) mass mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: o3mmr(:,:,:)         ! O3 (volume) mass mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: co2vmr(:,:,:)        ! CO2 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: ch4vmr(:,:,:)        ! Methane volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: n2ovmr(:,:,:)        ! Nitrous oxide volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: o2vmr             ! Oxygen volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc11vmr           ! CFC11 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc12vmr           ! CFC12 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc22vmr          ! CFC22 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: ccl4vmr            ! CCL4 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: emis(:,:,:)          ! Surface emissivity
                                                      !    Dimensions: (ncol,nbndlw)

      integer(kind=im), intent(in) :: inflglw         ! Flag for cloud optical properties
      integer(kind=im), intent(in) :: iceflglw        ! Flag for ice particle specification
      integer(kind=im), intent(in) :: liqflglw        ! Flag for liquid droplet specification

      real(kind=rb), intent(in) :: cldfr(:,:,:)         ! Cloud fraction
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cicewp(:,:,:)        ! Cloud ice water path (g/m2)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cliqwp(:,:,:)        ! Cloud liquid water path (g/m2)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: reice(:,:,:)         ! Cloud ice effective size (microns)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: reliq(:,:,:)         ! Cloud water drop effective radius (microns)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: taucld(:,:,:,:)      ! In-cloud optical depth
                                                      !    Dimensions: (nbndlw,ncol,nlay)
      real(kind=rb), intent(in) :: tauaer(:,:,:,:)      ! Aerosol optical depth
                                                      !    Dimensions: (ncol,nlay,nbndlw)
      logical, intent(in)       :: array_in           ! use optional arrays

! ----- Output -----
! Atmosphere
      integer(kind=im), intent(out) :: nlayers        ! number of layers

      real(kind=rb), intent(out) :: pavel(:)          ! layer pressures (mb) 
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: tavel(:)          ! layer temperatures (K)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: pz(0:nlay)            ! level (interface) pressures (hPa, mb)
                                                      !    Dimensions: (0:nlay)
      real(kind=rb), intent(out) :: tz(0:nlay)            ! level (interface) temperatures (K)
                                                      !    Dimensions: (0:nlay)
      real(kind=rb), intent(out) :: tbound            ! surface temperature (K)
      real(kind=rb), intent(out) :: coldry(:)         ! dry air column density (mol/cm2)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: wbrodl(:)         ! broadening gas column density (mol/cm2)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: wkl(:,:)          ! molecular amounts (mol/cm-2)
                                                      !    Dimensions: (mxmol,nlay)
      real(kind=rb), intent(out) :: wx(:,:)           ! cross-section amounts (mol/cm-2)
                                                      !    Dimensions: (maxxsec,nlay)
      real(kind=rb), intent(out) :: pwvcm             ! precipitable water vapor (cm)
      real(kind=rb), intent(out) :: semiss(:)         ! lw surface emissivity
                                                      !    Dimensions: (nbndlw)

! Atmosphere/clouds - cldprop
      integer(kind=im), intent(out) :: inflag         ! flag for cloud property method
      integer(kind=im), intent(out) :: iceflag        ! flag for ice cloud properties
      integer(kind=im), intent(out) :: liqflag        ! flag for liquid cloud properties

      real(kind=rb), intent(out) :: cldfrac(:)        ! layer cloud fraction
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: ciwp(:)           ! cloud ice water path
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: clwp(:)           ! cloud liquid water path
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: rel(:)            ! cloud liquid particle effective radius (microns)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: rei(:)            ! cloud ice particle effective size (microns)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: tauc(:,:)         ! in-cloud optical depth
                                                      !    Dimensions: (nbndlw,nlay)
      real(kind=rb), intent(out) :: taua(:,:)         ! aerosol optical depth
                                                      !    Dimensions: (nlay,nbndlw)
! optional array arguments for well mixed gasses
      
      real(kind=rb), intent(in), optional :: o2vmr_a(:,:,:)   ! Oxygen volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc11vmr_a(:,:,:) ! CFC11 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc12vmr_a(:,:,:) ! CFC12 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc22vmr_a(:,:,:) ! CFC22 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: ccl4vmr_a(:,:,:) ! CCL4 volume mixing ratio


! ----- Local -----
      real(kind=rb), parameter :: amd = 28.9660_rb    ! Effective molecular weight of dry air (g/mol)
      real(kind=rb), parameter :: amw = 18.0160_rb    ! Molecular weight of water vapor (g/mol)
!      real(kind=rb), parameter :: amc = 44.0098_rb    ! Molecular weight of carbon dioxide (g/mol)
      real(kind=rb), parameter :: amo = 47.9998_rb    ! Molecular weight of ozone (g/mol)
!      real(kind=rb), parameter :: amo2 = 31.9999_rb   ! Molecular weight of oxygen (g/mol)
!      real(kind=rb), parameter :: amch4 = 16.0430_rb  ! Molecular weight of methane (g/mol)
!      real(kind=rb), parameter :: amn2o = 44.0128_rb  ! Molecular weight of nitrous oxide (g/mol)
!      real(kind=rb), parameter :: amc11 = 137.3684_rb ! Molecular weight of CFC11 (g/mol) - CCL3F
!      real(kind=rb), parameter :: amc12 = 120.9138_rb ! Molecular weight of CFC12 (g/mol) - CCL2F2
!      real(kind=rb), parameter :: amc22 = 86.4688_rb  ! Molecular weight of CFC22 (g/mol) - CHCLF2
!      real(kind=rb), parameter :: amcl4 = 153.823_rb  ! Molecular weight of CCL4 (g/mol) - CCL4

! Set molecular weight ratios (for converting mmr to vmr)
!  e.g. h2ovmr = h2ommr * amdw)
      real(kind=rb), parameter :: amdw = 1.607793_rb  ! Molecular weight of dry air / water vapor
      real(kind=rb), parameter :: amdc = 0.658114_rb  ! Molecular weight of dry air / carbon dioxide
      real(kind=rb), parameter :: amdo = 0.603428_rb  ! Molecular weight of dry air / ozone
      real(kind=rb), parameter :: amdm = 1.805423_rb  ! Molecular weight of dry air / methane
      real(kind=rb), parameter :: amdn = 0.658090_rb  ! Molecular weight of dry air / nitrous oxide
      real(kind=rb), parameter :: amdo2 = 0.905140_rb ! Molecular weight of dry air / oxygen
      real(kind=rb), parameter :: amdc1 = 0.210852_rb ! Molecular weight of dry air / CFC11
      real(kind=rb), parameter :: amdc2 = 0.239546_rb ! Molecular weight of dry air / CFC12


      INTEGER(kind=im) :: isp, l, ix, n, imol, ib, i       ! Loop indices
      REAL(kind=rb) :: amm, amttl, wvttl, wvsh, summol , deltap 

! Add one to nlayers here to include extra model layer at top of atmosphere
!     nlayers = nlay-klow+2
 nlayers = nlay-klow+2

!  Initialize all molecular amounts and cloud properties to zero here, then pass input amounts
!  into RRTM arrays below.

      wkl(:,:) = 0.0_rb
      wx(:,:) = 0.0_rb
      cldfrac(:) = 0.0_rb
      tauc(:,:) = 0.0_rb
      ciwp(:) = 0.0_rb
      clwp(:) = 0.0_rb
      rei(:) = 0.0_rb
      rel(:) = 0.0_rb
      taua(:,:) = 0.0_rb
      amttl = 0.0_rb
      wvttl = 0.0_rb
 
!  Set surface temperature.
      tbound = tsfc(iplon,j)

!  Install input GCM arrays into RRTMG_LW arrays for pressure, temperature,
!  and molecular amounts.  
!  Pressures are input in mb, or are converted to mb here.
!  Molecular amounts are input in volume mixing ratio, or are converted from 
!  mass mixing ratio (or specific humidity for h2o) to volume mixing ratio
!  here. These are then converted to molecular amount (molec/cm2) below.  
!  The dry air column COLDRY (in molec/cm2) is calculated from the level 
!  pressures, pz (in mb), based on the hydrostatic equation and includes a 
!  correction to account for h2o in the layer.  The molecular weight of moist 
!  air (amm) is calculated for each layer.  
!  Note: In RRTMG, layer indexing goes from bottom to top, and coding below
!  assumes GCM input fields are also bottom to top. Input layer indexing
!  from GCM fields should be reversed here if necessary.

      !--------------------------------------------------------------------!
      ! one extra layer on top of atmosphere was added in order to allow   !
      ! for calcualtion of a heating rate at model top                     !
      ! some modifications had to be done in oder to make this work        !
      ! in the radiation in case                                           !
      !--------------------------------------------------------------------!

      pz(0) = plev(iplon,j,klow)
      tz(0) = tlev(iplon,j,klow)
      DO l = 1, nlayers -1 !-2
         pavel(l) = play(iplon,j,l+klow-1)
         tavel(l) = tlay(iplon,j,l+klow-1)
         pz(l) = plev(iplon,j,l+klow)
         tz(l) = tlev(iplon,j,l+klow)
! For h2o input in vmr:
!         wkl(1,l) = h2ovmr(iplon,j,l+klow-1)
! For h2o input in mmr:
         wkl(1,l) = h2ommr(iplon,j,l+klow-1)*amdw
! For h2o input in specific humidity;
!         wkl(1,l) = (h2o(iplon,j,l+klow-1)/(1._rb - h2o(iplon,j,l+klow-1)))*amdw
         wkl(2,l) = co2vmr(iplon,j,l+klow-1)
! For o3 input in vmr:
!         wkl(3,l) = o3vmr(iplon,j,l+klow-1)
! For h2o input in mmr:
         wkl(3,l) = o3mmr(iplon,j,l+klow-1)*amdo   
         wkl(4,l) = n2ovmr(iplon,j,l+klow-1)
         wkl(6,l) = ch4vmr(iplon,j,l+klow-1)
         wkl(7,l) = o2vmr  ! changed 
         if (present(o2vmr_a)) wkl(7,l) = o2vmr_a(iplon,j,l+klow-1)
         amm = (1._rb - wkl(1,l)) * amd + wkl(1,l) * amw            
         coldry(l) = (pz(l-1)-pz(l)) * 1.e3_rb * avogad / &
                     (1.e2_rb * grav * amm * (1._rb + wkl(1,l)))
      enddo

      pz(nlayers-1) = pavel(nlayers-1)-(pz(nlayers-2)-pavel(nlayers-1))
      tz(nlayers-1) = tavel(nlayers-1)-(tz(nlayers-2)-tavel(nlayers-1))
      coldry(nlayers-1) = (pz(nlayers-2)-pz(nlayers-1)) * 1.e3_rb * avogad / &
                     (1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers-1)))

!--------------------------------------------------------------------------!
!                                                                          !
! additonal layer added with linear gradient for pressure and temperature  !
! absorber concentrations are taken from nlayers-1                         !
!__________________________________________________________________________!


      pavel(nlayers) = pavel(nlayers-1)-(pavel(nlayers-2)-pavel(nlayers-1))
      tavel(nlayers) = tavel(nlayers-1)-(tavel(nlayers-2)-tavel(nlayers-1))
      pz(nlayers) = pavel(nlayers)-(pz(nlayers-1)-pavel(nlayers))
      tz(nlayers) = tavel(nlayers)-(tz(nlayers-1)-tavel(nlayers))
! For h2o input in vmr:
!      wkl(1,nlayers) = h2ovmr(iplon,j,nlay)
! For h2o input in mmr:
      wkl(1,nlayers) = h2ommr(iplon,j,nlay)*amdw
! For h2o input in specific humidity;
!      wkl(1,nlayers) = (h2o(iplon,j,nlay)/(1._rb - h2o(iplon,j,nlay)))*amdw
      wkl(2,nlayers) = co2vmr(iplon,j,nlay)
! For o3 input in vmr:
!        wkl(3,nlayers) = o3vmr(iplon,j,nlay)
! For h2o input in mmr:
      wkl(3,nlayers) = o3mmr(iplon,j,nlay)*amdo   
      wkl(4,nlayers) = n2ovmr(iplon,j,nlay)
      wkl(6,nlayers) = ch4vmr(iplon,j,nlay)
      wkl(7,nlayers) = o2vmr  ! changed 
      IF (PRESENT(o2vmr_a)) wkl(7,nlayers-1) = o2vmr_a(iplon,j,nlay)
      amm = (1._rb - wkl(1,l)) * amd + wkl(1,l) * amw            
      coldry(nlayers) = (pz(nlayers-1)-pz(nlayers)) * 1.e3_rb * avogad &
                           /(1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers)))


! Set cross section molecule amounts from input; convert to vmr if necessary

      wx(1,:) = ccl4vmr
      wx(2,:) = cfc11vmr
      wx(3,:) = cfc12vmr
      wx(4,:) = cfc22vmr
         
      if(array_in) then
         do l = 1, nlayers-1 
            wx(1,l) = ccl4vmr_a(iplon,j,l+klow-1)
            wx(2,l) = cfc11vmr_a(iplon,j,l+klow-1)
            wx(3,l) = cfc12vmr_a(iplon,j,l+klow-1)
            wx(4,l) = cfc22vmr_a(iplon,j,l+klow-1)
         end do
      end if

!--------------------------------------------------------------------------!
!                                                                          !
! following section is the alternative for full atmosphere profile         !
! see inatm subroutine                                                     !
!__________________________________________________________________________!


! The following section can be used to set values for an additional layer (from
! the GCM top level to 1.e-4 mb) for improved calculation of TOA fluxes. 
! Temperature and molecular amounts in the extra model layer are set to 
! their values in the top GCM model layer, though these can be modified
! here if necessary. 
! If this feature is utilized, increase nlayers by one above, limit the two
! loops above to (nlayers-1), and set the top most (extra) layer values here. 

   !   IF (SUM(rad_down) .LT. 1.e-10) THEN
   !      pavel(nlayers) = 0.5_rb * pz(nlayers-1)
    !     pz(nlayers) = 1.e-4_rb
 !    ELSE
 !       pz(nlayers) = 2*pz(nlayers-1)-pz(nlayers-2)
 !        pavel(nlayers) = 2*pavel(nlayers-1)-pavel(nlayers-2)
!      END IF
!      tavel(nlayers) = tavel(nlayers-1)      
!      tz(nlayers-1) = 0.5_rb * (tavel(nlayers)+tavel(nlayers-1))
!      tz(nlayers) = tz(nlayers-1)
!      wkl(1,nlayers) = wkl(1,nlayers-1)
!      wkl(2,nlayers) = wkl(2,nlayers-1)
!      wkl(3,nlayers) = wkl(3,nlayers-1)
!      wkl(4,nlayers) = wkl(4,nlayers-1)
!      wkl(6,nlayers) = wkl(6,nlayers-1)
!      wkl(7,nlayers) = wkl(7,nlayers-1)
!      amm = (1._rb - wkl(1,nlayers-1)) * amd + wkl(1,nlayers-1) * amw
   !   IF (SUM(rad_down) .LT. 1.e-10) THEN
!         coldry(nlayers) = (pz(nlayers-1)) * 1.e3_rb * avogad / &
 !                       (1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers-1)))
   !   ELSE
   !      coldry(nlayers) = (pz(nlayers-1)-pz(nlayers)) * 1.e3_rb * avogad / &
  !                       (1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers-1)))
   !   END IF
     ! coldry(nlayers) = (pz(nlayers-1)) * 1.e3_rb * avogad / &
     !                   (1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers-1)))
 !     wx(1,nlayers) = wx(1,nlayers-1)
 !     wx(2,nlayers) = wx(2,nlayers-1)
 !     wx(3,nlayers) = wx(3,nlayers-1)
 !     wx(4,nlayers) = wx(4,nlayers-1)

! At this point all moleculular amounts in wkl and wx are in volume mixing ratio; 
! convert to molec/cm2 based on coldry for use in rrtm.  also, compute precipitable
! water vapor for diffusivity angle adjustments in rtrn and rtrnmr.

     do l = 1, nlayers  
         summol = 0.0_rb
         do imol = 2, nmol
            summol = summol + wkl(imol,l)
         enddo
         wbrodl(l) = coldry(l) * (1._rb - summol)
         do imol = 1, nmol
            wkl(imol,l) = coldry(l) * wkl(imol,l)
         enddo
         amttl = amttl + coldry(l)+wkl(1,l)
         wvttl = wvttl + wkl(1,l)
         do ix = 1,maxxsec
            if (ixindx(ix) .ne. 0) then
               wx(ixindx(ix),l) = coldry(l) * wx(ix,l) * 1.e-20_rb
            endif
         enddo
      enddo

      wvsh = (amw * wvttl) / (amd * amttl)
      pwvcm = wvsh * (1.e3_rb * pz(0)) / (1.e2_rb * grav)

! Set spectral surface emissivity for each longwave band.  

      do n=1,nbndlw
         semiss(n) = emis(iplon,j,n)
!          semiss(n) = 1.0_rb
      enddo

! Transfer aerosol optical properties to RRTM variable;
! modify to reverse layer indexing here if necessary.

     if (iaer .ge. 1) then
         do l = 1, nlayers-1
           do ib = 1, nbndlw
              taua(l,ib) = tauaer(iplon,j,l+klow-1,ib)
           enddo
        enddo
      endif

! Transfer cloud fraction and cloud optical properties to RRTM variables,
! modify to reverse layer indexing here if necessary.

      if (icld .ge. 1) then 
         inflag = inflglw
         iceflag = iceflglw
         liqflag = liqflglw

! Move incoming GCM cloud arrays to RRTMG cloud arrays.
! For GCM input, incoming reice is defined based on selected ice parameterization (inflglw)

         DO l = 1, nlayers-1 !nlayers-1
            cldfrac(l) = cldfr(iplon,j,l+klow-1)
            ciwp(l) = cicewp(iplon,j,l+klow-1)
            clwp(l) = cliqwp(iplon,j,l+klow-1)
            rei(l) = reice(iplon,j,l+klow-1)
            rel(l) = reliq(iplon,j,l+klow-1)
            do n=1,nbndlw
               tauc(n,l) = taucld(n,iplon,j,l+klow-1)
!               ssac(n,l) = ssacld(n,iplon,l)
!               asmc(n,l) = asmcld(n,iplon,l)
            enddo
         enddo

! If extra layers are being used in RRTMG, set all cloud properties to zero in the extra layer.


         cldfrac(nlayers) = 0.0_rb
         tauc(:nbndlw,nlayers) = 0.0_rb
         ciwp(nlayers) = 0.0_rb
         clwp(nlayers) = 0.0_rb
         rei(nlayers) = 0.0_rb
         rel(nlayers) = 0.0_rb
         taua(nlayers,:) = 0.0_rb

      endif
      
    END SUBROUTINE inatm_radin

!***************************************************************************
      subroutine inatm (iplon, j, nlay, icld, iaer, &
              play, plev, tlay, tlev, tsfc, h2ommr, &
              o3mmr, co2vmr, ch4vmr, n2ovmr, o2vmr, cfc11vmr, cfc12vmr, &
              cfc22vmr, ccl4vmr, emis, inflglw, iceflglw, liqflglw, &
              cldfr, taucld, cicewp, cliqwp, reice, reliq, tauaer, &
              nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
              wkl, wbrodl, wx, pwvcm, inflag, iceflag, liqflag, &
              cldfrac, tauc, ciwp, clwp, rei, rel, taua, klow, array_in, &
              o2vmr_a, cfc11vmr_a, cfc12vmr_a, cfc22vmr_a, ccl4vmr_a)
!***************************************************************************
!
!  Input atmospheric profile from GCM, and prepare it for use in RRTMG_LW.
!  Set other RRTMG_LW input parameters.  
!
!***************************************************************************

! --------- Modules ----------

      use parrrtm, only : nbndlw, ngptlw, nmol, maxxsec, mxmol
      use rrlw_con, only: fluxfac, heatfac, oneminus, pi, grav, avogad
      use rrlw_wvn, only: ng, nspa, nspb, wavenum1, wavenum2, delwave, ixindx

! ------- Declarations -------

! ----- Input -----
! Note: All volume mixing ratios are in dimensionless units of mole fraction obtained
! by scaling mass mixing ratio (g/g) with the appropriate molecular weights (g/mol) 

      integer(kind=im), intent(in) :: klow            ! first active k 
      integer(kind=im), intent(in) :: iplon, j        ! column loop indeces
      integer(kind=im), intent(in) :: nlay            ! Number of model layers
      integer(kind=im), intent(in) :: icld            ! clear/cloud and cloud overlap flag
      integer(kind=im), intent(in) :: iaer            ! aerosol option flag

      real(kind=rb), intent(in) :: play(:,:,:)          ! Layer pressures (hPa, mb)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: plev(:,:,:)          ! Interface pressures (hPa, mb)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(in) :: tlay(:,:,:)          ! Layer temperatures (K)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: tlev(:,:,:)          ! Interface temperatures (K)
                                                      !    Dimensions: (ncol,nlay+1)
      real(kind=rb), intent(in) :: tsfc(:,:)            ! Surface temperature (K)
                                                      !    Dimensions: (ncol)
      real(kind=rb), intent(in) :: h2ommr(:,:,:)        ! H2O (volume) mass mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: o3mmr(:,:,:)         ! O3 (volume) mass mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: co2vmr(:,:,:)        ! CO2 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: ch4vmr(:,:,:)        ! Methane volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: n2ovmr(:,:,:)        ! Nitrous oxide volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: o2vmr             ! Oxygen volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc11vmr           ! CFC11 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc12vmr           ! CFC12 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cfc22vmr          ! CFC22 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: ccl4vmr            ! CCL4 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: emis(:,:,:)          ! Surface emissivity
                                                      !    Dimensions: (ncol,nbndlw)

      integer(kind=im), intent(in) :: inflglw         ! Flag for cloud optical properties
      integer(kind=im), intent(in) :: iceflglw        ! Flag for ice particle specification
      integer(kind=im), intent(in) :: liqflglw        ! Flag for liquid droplet specification

      real(kind=rb), intent(in) :: cldfr(:,:,:)         ! Cloud fraction
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cicewp(:,:,:)        ! Cloud ice water path (g/m2)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: cliqwp(:,:,:)        ! Cloud liquid water path (g/m2)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: reice(:,:,:)         ! Cloud ice effective size (microns)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: reliq(:,:,:)         ! Cloud water drop effective radius (microns)
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in) :: taucld(:,:,:,:)      ! In-cloud optical depth
                                                      !    Dimensions: (nbndlw,ncol,nlay)
      real(kind=rb), intent(in) :: tauaer(:,:,:,:)      ! Aerosol optical depth
                                                      !    Dimensions: (ncol,nlay,nbndlw)
      logical, intent(in)       :: array_in           ! use optional arrays

! ----- Output -----
! Atmosphere
      integer(kind=im), intent(out) :: nlayers        ! number of layers

      real(kind=rb), intent(out) :: pavel(:)          ! layer pressures (mb) 
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: tavel(:)          ! layer temperatures (K)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: pz(0:nlay)            ! level (interface) pressures (hPa, mb)
                                                      !    Dimensions: (0:nlay)
      real(kind=rb), intent(out) :: tz(0:nlay)            ! level (interface) temperatures (K)
                                                      !    Dimensions: (0:nlay)
      real(kind=rb), intent(out) :: tbound            ! surface temperature (K)
      real(kind=rb), intent(out) :: coldry(:)         ! dry air column density (mol/cm2)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: wbrodl(:)         ! broadening gas column density (mol/cm2)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: wkl(:,:)          ! molecular amounts (mol/cm-2)
                                                      !    Dimensions: (mxmol,nlay)
      real(kind=rb), intent(out) :: wx(:,:)           ! cross-section amounts (mol/cm-2)
                                                      !    Dimensions: (maxxsec,nlay)
      real(kind=rb), intent(out) :: pwvcm             ! precipitable water vapor (cm)
      real(kind=rb), intent(out) :: semiss(:)         ! lw surface emissivity
                                                      !    Dimensions: (nbndlw)

! Atmosphere/clouds - cldprop
      integer(kind=im), intent(out) :: inflag         ! flag for cloud property method
      integer(kind=im), intent(out) :: iceflag        ! flag for ice cloud properties
      integer(kind=im), intent(out) :: liqflag        ! flag for liquid cloud properties

      real(kind=rb), intent(out) :: cldfrac(:)        ! layer cloud fraction
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: ciwp(:)           ! cloud ice water path
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: clwp(:)           ! cloud liquid water path
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: rel(:)            ! cloud liquid particle effective radius (microns)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: rei(:)            ! cloud ice particle effective size (microns)
                                                      !    Dimensions: (nlay)
      real(kind=rb), intent(out) :: tauc(:,:)         ! in-cloud optical depth
                                                      !    Dimensions: (nbndlw,nlay)
      real(kind=rb), intent(out) :: taua(:,:)         ! aerosol optical depth
                                                      !    Dimensions: (nlay,nbndlw)
! optional array arguments for well mixed gasses
      
      real(kind=rb), intent(in), optional :: o2vmr_a(:,:,:)   ! Oxygen volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc11vmr_a(:,:,:) ! CFC11 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc12vmr_a(:,:,:) ! CFC12 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: cfc22vmr_a(:,:,:) ! CFC22 volume mixing ratio
                                                      !    Dimensions: (ncol,nlay)
      real(kind=rb), intent(in), optional :: ccl4vmr_a(:,:,:) ! CCL4 volume mixing ratio


! ----- Local -----
      real(kind=rb), parameter :: amd = 28.9660_rb    ! Effective molecular weight of dry air (g/mol)
      real(kind=rb), parameter :: amw = 18.0160_rb    ! Molecular weight of water vapor (g/mol)
!      real(kind=rb), parameter :: amc = 44.0098_rb    ! Molecular weight of carbon dioxide (g/mol)
      real(kind=rb), parameter :: amo = 47.9998_rb    ! Molecular weight of ozone (g/mol)
!      real(kind=rb), parameter :: amo2 = 31.9999_rb   ! Molecular weight of oxygen (g/mol)
!      real(kind=rb), parameter :: amch4 = 16.0430_rb  ! Molecular weight of methane (g/mol)
!      real(kind=rb), parameter :: amn2o = 44.0128_rb  ! Molecular weight of nitrous oxide (g/mol)
!      real(kind=rb), parameter :: amc11 = 137.3684_rb ! Molecular weight of CFC11 (g/mol) - CCL3F
!      real(kind=rb), parameter :: amc12 = 120.9138_rb ! Molecular weight of CFC12 (g/mol) - CCL2F2
!      real(kind=rb), parameter :: amc22 = 86.4688_rb  ! Molecular weight of CFC22 (g/mol) - CHCLF2
!      real(kind=rb), parameter :: amcl4 = 153.823_rb  ! Molecular weight of CCL4 (g/mol) - CCL4

! Set molecular weight ratios (for converting mmr to vmr)
!  e.g. h2ovmr = h2ommr * amdw)
      real(kind=rb), parameter :: amdw = 1.607793_rb  ! Molecular weight of dry air / water vapor
      real(kind=rb), parameter :: amdc = 0.658114_rb  ! Molecular weight of dry air / carbon dioxide
      real(kind=rb), parameter :: amdo = 0.603428_rb  ! Molecular weight of dry air / ozone
      real(kind=rb), parameter :: amdm = 1.805423_rb  ! Molecular weight of dry air / methane
      real(kind=rb), parameter :: amdn = 0.658090_rb  ! Molecular weight of dry air / nitrous oxide
      real(kind=rb), parameter :: amdo2 = 0.905140_rb ! Molecular weight of dry air / oxygen
      real(kind=rb), parameter :: amdc1 = 0.210852_rb ! Molecular weight of dry air / CFC11
      real(kind=rb), parameter :: amdc2 = 0.239546_rb ! Molecular weight of dry air / CFC12


      integer(kind=im) :: isp, l, ix, n, imol, ib       ! Loop indices
      real(kind=rb) :: amm, amttl, wvttl, wvsh, summol  

! Add one to nlayers here to include extra model layer at top of atmosphere
      nlayers = nlay-klow+2

!  Initialize all molecular amounts and cloud properties to zero here, then pass input amounts
!  into RRTM arrays below.

      wkl(:,:) = 0.0_rb
      wx(:,:) = 0.0_rb
      cldfrac(:) = 0.0_rb
      tauc(:,:) = 0.0_rb
      ciwp(:) = 0.0_rb
      clwp(:) = 0.0_rb
      rei(:) = 0.0_rb
      rel(:) = 0.0_rb
      taua(:,:) = 0.0_rb
      amttl = 0.0_rb
      wvttl = 0.0_rb
 
!  Set surface temperature.
      tbound = tsfc(iplon,j)

!  Install input GCM arrays into RRTMG_LW arrays for pressure, temperature,
!  and molecular amounts.  
!  Pressures are input in mb, or are converted to mb here.
!  Molecular amounts are input in volume mixing ratio, or are converted from 
!  mass mixing ratio (or specific humidity for h2o) to volume mixing ratio
!  here. These are then converted to molecular amount (molec/cm2) below.  
!  The dry air column COLDRY (in molec/cm2) is calculated from the level 
!  pressures, pz (in mb), based on the hydrostatic equation and includes a 
!  correction to account for h2o in the layer.  The molecular weight of moist 
!  air (amm) is calculated for each layer.  
!  Note: In RRTMG, layer indexing goes from bottom to top, and coding below
!  assumes GCM input fields are also bottom to top. Input layer indexing
!  from GCM fields should be reversed here if necessary.

      !--------------------------------------------------------------------!
      ! one extra layer on top of atmosphere was added in order to improve !
      ! heating rate at the top of ATHAM.                                  !
      ! some modifications had to be done in oder to make this work        !
      ! nlayer-1 and nlayer hat to be treated separatly                    !
      !--------------------------------------------------------------------!

      pz(0) = plev(iplon,j,klow)
      tz(0) = tlev(iplon,j,klow)
      do l = 1, nlayers-2 
         pavel(l) = play(iplon,j,l+klow-1)
         tavel(l) = tlay(iplon,j,l+klow-1)
         pz(l) = plev(iplon,j,l+klow)
         tz(l) = tlev(iplon,j,l+klow)
! For h2o input in vmr:
!         wkl(1,l) = h2ovmr(iplon,j,l+klow-1)
! For h2o input in mmr:
         wkl(1,l) = h2ommr(iplon,j,l+klow-1)*amdw
! For h2o input in specific humidity;
!         wkl(1,l) = (h2o(iplon,j,l+klow-1)/(1._rb - h2o(iplon,j,l+klow-1)))*amdw
         wkl(2,l) = co2vmr(iplon,j,l+klow-1)
! For o3 input in vmr:
!         wkl(3,l) = o3vmr(iplon,j,l+klow-1)
! For h2o input in mmr:
         wkl(3,l) = o3mmr(iplon,j,l+klow-1)*amdo   
         wkl(4,l) = n2ovmr(iplon,j,l+klow-1)
         wkl(6,l) = ch4vmr(iplon,j,l+klow-1)
         wkl(7,l) = o2vmr  ! changed 
         if (present(o2vmr_a)) wkl(7,l) = o2vmr_a(iplon,j,l+klow-1)
         amm = (1._rb - wkl(1,l)) * amd + wkl(1,l) * amw            
         coldry(l) = (pz(l-1)-pz(l)) * 1.e3_rb * avogad / &
                     (1.e2_rb * grav * amm * (1._rb + wkl(1,l)))
      enddo

         pavel(nlayers-1) = play(iplon,j,nlay)
         tavel(nlayers-1) = tlay(iplon,j,nlay)
         pz(nlayers-1)    =play(iplon,j,nlay)-  &
                           (plev(iplon,j,nlay)-play(iplon,j,nlay))
! For h2o input in vmr:
!         wkl(1,nlayers-1) = h2ovmr(iplon,j,nlay)
! For h2o input in mmr:
         wkl(1,nlayers-1) = h2ommr(iplon,j,nlay)*amdw
! For h2o input in specific humidity;
!         wkl(1,nlayers-1) = (h2o(iplon,j,nlay)/(1._rb - h2o(iplon,j,nlay)))*amdw
         wkl(2,nlayers-1) = co2vmr(iplon,j,nlay)
! For o3 input in vmr:
!         wkl(3,nlayers-1) = o3vmr(iplon,j,nlay)
! For h2o input in mmr:
         wkl(3,nlayers-1) = o3mmr(iplon,j,nlay)*amdo   
         wkl(4,nlayers-1) = n2ovmr(iplon,j,nlay)
         wkl(6,nlayers-1) = ch4vmr(iplon,j,nlay)
         wkl(7,nlayers-1) = o2vmr  ! changed 
         if (present(o2vmr_a)) wkl(7,nlayers-1) = o2vmr_a(iplon,j,nlay)
         amm = (1._rb - wkl(1,l)) * amd + wkl(1,l) * amw            
         coldry(nlayers-1) = (pz(nlayers-2)-pz(nlayers-1)) * 1.e3_rb * avogad &
                           /(1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers-1)))


! Set cross section molecule amounts from input; convert to vmr if necessary

      wx(1,:) = ccl4vmr
      wx(2,:) = cfc11vmr
      wx(3,:) = cfc12vmr
      wx(4,:) = cfc22vmr
         
      if(array_in) then
         do l = 1, nlayers-1 
            wx(1,l) = ccl4vmr_a(iplon,j,l+klow-1)
            wx(2,l) = cfc11vmr_a(iplon,j,l+klow-1)
            wx(3,l) = cfc12vmr_a(iplon,j,l+klow-1)
            wx(4,l) = cfc22vmr_a(iplon,j,l+klow-1)
         end do
      end if

! The following section can be used to set values for an additional layer (from
! the GCM top level to 1.e-4 mb) for improved calculation of TOA fluxes. 
! Temperature and molecular amounts in the extra model layer are set to 
! their values in the top GCM model layer, though these can be modified
! here if necessary. 
! If this feature is utilized, increase nlayers by one above, limit the two
! loops above to (nlayers-1), and set the top most (extra) layer values here. 

      pavel(nlayers) = 0.5_rb * pz(nlayers-1)
      tavel(nlayers) = tavel(nlayers-1)
      pz(nlayers) = 1.e-4_rb
      tz(nlayers-1) = 0.5_rb * (tavel(nlayers)+tavel(nlayers-1))
      tz(nlayers) = tz(nlayers-1)
      wkl(2,nlayers) = wkl(2,nlayers-1)
      wkl(3,nlayers) = wkl(3,nlayers-1)
      wkl(4,nlayers) = wkl(4,nlayers-1)
      wkl(6,nlayers) = wkl(6,nlayers-1)
      wkl(7,nlayers) = wkl(7,nlayers-1)
      amm = (1._rb - wkl(1,nlayers-1)) * amd + wkl(1,nlayers-1) * amw
      coldry(nlayers) = (pz(nlayers-1)) * 1.e3_rb * avogad / &
                        (1.e2_rb * grav * amm * (1._rb + wkl(1,nlayers-1)))
      wx(1,nlayers) = wx(1,nlayers-1)
      wx(2,nlayers) = wx(2,nlayers-1)
      wx(3,nlayers) = wx(3,nlayers-1)
      wx(4,nlayers) = wx(4,nlayers-1)

! At this point all moleculular amounts in wkl and wx are in volume mixing ratio; 
! convert to molec/cm2 based on coldry for use in rrtm.  also, compute precipitable
! water vapor for diffusivity angle adjustments in rtrn and rtrnmr.

     do l = 1, nlayers  
         summol = 0.0_rb
         do imol = 2, nmol
            summol = summol + wkl(imol,l)
         enddo
         wbrodl(l) = coldry(l) * (1._rb - summol)
         do imol = 1, nmol
            wkl(imol,l) = coldry(l) * wkl(imol,l)
         enddo
         amttl = amttl + coldry(l)+wkl(1,l)
         wvttl = wvttl + wkl(1,l)
         do ix = 1,maxxsec
            if (ixindx(ix) .ne. 0) then
               wx(ixindx(ix),l) = coldry(l) * wx(ix,l) * 1.e-20_rb
            endif
         enddo
      enddo

      wvsh = (amw * wvttl) / (amd * amttl)
      pwvcm = wvsh * (1.e3_rb * pz(0)) / (1.e2_rb * grav)

! Set spectral surface emissivity for each longwave band.  

      do n=1,nbndlw
         semiss(n) = emis(iplon,j,n)
!          semiss(n) = 1.0_rb
      enddo

! Transfer aerosol optical properties to RRTM variable;
! modify to reverse layer indexing here if necessary.

     if (iaer .ge. 1) then
         do l = 1, nlayers-1
           do ib = 1, nbndlw
              taua(l,ib) = tauaer(iplon,j,l+klow-1,ib)
           enddo
        enddo
      endif

! Transfer cloud fraction and cloud optical properties to RRTM variables,
! modify to reverse layer indexing here if necessary.

      if (icld .ge. 1) then 
         inflag = inflglw
         iceflag = iceflglw
         liqflag = liqflglw

! Move incoming GCM cloud arrays to RRTMG cloud arrays.
! For GCM input, incoming reice is defined based on selected ice parameterization (inflglw)

         do l = 1, nlayers-1 
            cldfrac(l) = cldfr(iplon,j,l+klow-1)
            ciwp(l) = cicewp(iplon,j,l+klow-1)
            clwp(l) = cliqwp(iplon,j,l+klow-1)
            rei(l) = reice(iplon,j,l+klow-1)
            rel(l) = reliq(iplon,j,l+klow-1)
            do n=1,nbndlw
               tauc(n,l) = taucld(n,iplon,j,l+klow-1)
!               ssac(n,l) = ssacld(n,iplon,l)
!               asmc(n,l) = asmcld(n,iplon,l)
            enddo
         enddo

! If an extra layer is being used in RRTMG, set all cloud properties to zero in the extra layer.

         cldfrac(nlayers) = 0.0_rb
         tauc(:nbndlw,nlayers) = 0.0_rb
         ciwp(nlayers) = 0.0_rb
         clwp(nlayers) = 0.0_rb
         rei(nlayers) = 0.0_rb
         rel(nlayers) = 0.0_rb
         taua(nlayers,:) = 0.0_rb

      endif
      
      end subroutine inatm

!*********************************************************************************

      end module rrtmg_lw_rad

