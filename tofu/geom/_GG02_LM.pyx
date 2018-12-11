# cython: boundscheck=False
# cython: wraparound=False
# cython; nonecheck=False
# cython: cdivision=True
#
cimport numpy as np
cimport cython
#
from libc.math cimport sqrt as Csqrt, ceil as Cceil, fabs as Cabs
from libc.math cimport floor as Cfloor, log2 as Clog2
from libc.math cimport cos as Ccos, acos as Cacos, sin as Csin, asin as Casin
from libc.math cimport atan2 as Catan2, pi as Cpi
from libc.math cimport NAN as Cnan
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.array cimport array, clone
from cython.parallel import prange

import numpy as np
cdef double _VSMALL = 1.e-9
cdef double _SMALL = 1.e-6


# =============================================================================
# = Set of functions for Ray-tracing
# =============================================================================


def LOS_Calc_PInOut_VesStruct(double[:, ::1] Ds,    double[:, ::1] dus,
                              double[:, ::1] VPoly, double[:, ::1] VIn,
                              int nstruct=0, int nLim=-1,
                              double[:] Lim=None,
                              list LSPoly=None, list LSLim=None,
                              long[::1] lSnLim=None, list LSVIn=None,
                              double RMin=-1,
                              double EpsUz=_VSMALL*1.,     double EpsA=_VSMALL*1.,
                              double EpsVz=_VSMALL*1., double EpsB=_VSMALL*1.,
                              double EpsPlane=_SMALL*1.,


                              str VType='Tor',
                              bint Forbid=1, bint Test=1):
    """
    Computes the entry and exit point of all provided LOS for the provided
    vessel polygon (toroidal or linear) with its associated structures.
    Return the normal vector at impact and the index of the impact segment

    Params
    ======
    Ds : (3, num_los) double array
       LOS origin points coordinates
    us : (3, num_los) double array
       LOS normalized direction vector
    VPoly : (2, num_vertex) double array
       Coordinates of the vertices of the Polygon defining the 2D poloidal
       cut of the Vessel
    VIn : (2, num_vertex-1) double array
       Normal vectors going "inwards" of the edges of the Polygon defined
       by VPoly
    nLim : int
       Number of limits of the vessel
           -1 : no limits, vessel continuous all around
            1 : vessel is limited
    Lim : array
       If nLim==1 contains the limits min and max of vessel
    nstruct : int
       Total number of structures (counting each limited structure as one)
    LSPoly : list
       List of coordinates of the vertices of all structures on poloidal plane
    LSLim : list
       List of limits of all structures
    LSnLim : array of ints
       List of number of limits for all structures
    LSVIn : list
       List of coordinates of "inwards" normal vectors of the polygon of all
       the structures
    RMin : double
       Minimal radius of vessel to take into consideration
    Eps<val> : double
       Small value, acceptance of error
    Vtype : string
       Type of vessel ("Tor" or "Lin")
    Forbid : bool
       Should we forbid values behind vissible radius ? (see Rmin)
    Test : bool
       Should we run tests ?

    Return
    ======
    kPIn : (num_los) array
       scalars level of "in" intersection of the LOS (if k=0 at origin)
    kPOut : (num_los) array
       scalars level of "out" intersection of the LOS (if k=0 at origin)
    VperpOut : (3, num_los) array
       Coordinates of the normal vector of impact of the LOS (NaN if none)
    IOut : (3, num_los)
       Index of structure impacted by LOS: IOut[:,ind_los]=(i,j,k) where k is
       the index of edge impacted on the j-th sub structure of the structure
       number i. If the LOS impacted the vessel i=j=0
    """

    cdef int ii, jj, kk
    cdef int ind_lim_data = 0
    cdef int len_lspoly = 0
    cdef bint found_new_kout
    cdef bint lim_is_none = 1
    cdef bint bool1, bool2
    cdef double val_rmin
    cdef double kpin_jj
    cdef double kpout_jj
    cdef double L0 = 0., L1 = 0.
    cdef bint inter_bbox
    cdef int ind_tmp
    cdef int len_lim
    cdef int num_los = Ds.shape[1]
    cdef int Ns = VIn.shape[1]
    cdef int size_lspoly
    cdef bint Forbidbis, Forbid0
    cdef double upscaDp, upar2, Dpar2, Crit2, invDpar2, rmin2
    cdef double L = 0., S1X = 0., S1Y = 0., S2X = 0., S2Y = 0.
    cdef double Crit2_base = EpsUz*EpsUz/400.
    cdef double[3] loc_vp
    cdef double[3] last_pout
    cdef double[6] bounds
    cdef double[1] kpin_loc, kpout_loc
    cdef double[3] loc_ds
    cdef double[3] loc_us
    cdef double[2] lim_ves
    cdef double[3] invr_ray
    cdef int[3] sign_ray
    cdef int[1] ind_loc
    cdef str error_message
    cdef double *lbounds = <double *>PyMem_Malloc(nstruct * 6 * sizeof(double))
    cdef double *langles = <double *>PyMem_Malloc(nstruct * 2 * sizeof(double))
    #cdef double[:, ::1] lspoly_view
    cdef int nvert
    cdef array kPIn  = clone(array('d'), num_los, False)
    cdef array kPOut = clone(array('d'), num_los, False)
    cdef array VperpOut  = clone(array('d'), num_los*3, False)
    cdef array IOut  = clone(array('i'), num_los*3, False)
    cdef int *llim_ves = <int *>PyMem_Malloc(nstruct * sizeof(int))

    if Test:
        error_message = "Ds and dus must be of the same shape: (3,) or (3,NL)!"
        assert tuple(Ds.shape) == tuple(dus.shape) and \
            Ds.shape[0] == 3, error_message
        error_message = "VPoly and VIn must be of the same shape (2,NS)!"
        assert VPoly.shape[0] == 2 and VIn.shape[0] == 2 and \
            Ns == VPoly.shape[1]-1, error_message
        bool1 = LSLim is None or len(LSLim) == len(LSPoly)
        bool2 = LSVIn is None or len(LSVIn) == len(LSPoly)
        error_message = "LSPoly,LSLim,LSVIn must be None or lists of same len!"
        assert bool1 and bool2, error_message
        error_message = "[EpsUz,EpsVz,EpsA,EpsB] must be floats < 1.e-4!"
        assert all([ee < 1.e-4 for ee in [EpsUz, EpsVz,
                                        EpsA, EpsB, EpsPlane]]), error_message
        error_message = "VType must be a str in ['Tor','Lin']!"
        assert VType.lower() in ['tor', 'lin'], error_message

    # if there are any, we get all the limits for the structures
    # and we compute the bounding boxs coordinates
    if lSnLim is not None:
        ind_lim_data = 0
        len_lspoly = len(lSnLim) # same as len(lspoly)
        # For each limited structure
        for ii in range(len_lspoly):
            # we get the structure polynome and its number of vertex
            # lspoly_view = LSPoly[ii] # is this really faster 
            # nvert = lspoly_view.shape[1]
            nvert = len(LSPoly[ii][0])
            #... and its limits:
            len_lim = lSnLim[ii]
            if len_lim == 0:
                lslim = [None]
                lSnLim[ii] = lSnLim[ii] + 1
            elif len_lim == 1:
                lslim = [[LSLim[ii][0, 0], LSLim[ii][0, 1]]]
            else:
                lslim = LSLim[ii]
            for jj in range(max(len_lim,1)):
                # We compute the structure's bounding box:
                if lslim[jj] is not None:
                    lim_ves[0] = lslim[jj][0]
                    lim_ves[1] = lslim[jj][1]
                    llim_ves[ind_lim_data] = 0 # False : struct is limited
                    L0 = Catan2(Csin(lim_ves[0]), Ccos(lim_ves[0]))
                    L1 = Catan2(Csin(lim_ves[1]), Ccos(lim_ves[1]))
                    compute_bbox_lim(nvert, LSPoly[ii], bounds, L0, L1)
                else:
                    llim_ves[ind_lim_data] = 1 # True : is continous
                    compute_bbox_extr(nvert, LSPoly[ii], bounds)
                    L0 = 0.
                    L1 = 0.
                langles[ind_lim_data*2] = L0
                langles[ind_lim_data*2 + 1] = L1
                for kk in range(6):
                    lbounds[ind_lim_data*6 + kk] = bounds[kk]
                ind_lim_data = 1 + ind_lim_data

    # if there are, we get the limits for the vessel
    if nLim == 0:
        lim_is_none = 1
    elif nLim == 1:
        lim_is_none = 0
        lim_ves[0] = Lim[0]
        lim_ves[1] = Lim[1]
        L0 = Catan2(Csin(lim_ves[0]), Ccos(lim_ves[0]))
        L1 = Catan2(Csin(lim_ves[1]), Ccos(lim_ves[1]))

    if VType.lower() == 'tor':
        # RMin is necessary to avoid looking on the other side of the tokamak
        if RMin < 0.:
            val_rmin = 0.95*min(np.min(VPoly[0, ...]),
                                np.min(np.hypot(Ds[0, ...],Ds[1, ...])))
        else:
            val_rmin = RMin
        rmin2 = val_rmin*val_rmin
        # Main function to compute intersections with Vessel
        ################
        # Compute
        if Forbid:
            Forbid0, Forbidbis = 1, 1
        else:
            Forbid0, Forbidbis = 0, 0
        for ii in range(num_los):
            loc_us[0] = dus[0, ii]
            loc_us[1] = dus[1, ii]
            loc_us[2] = dus[2, ii]
            loc_ds[0] = Ds[0, ii]
            loc_ds[1] = Ds[1, ii]
            loc_ds[2] = Ds[2, ii]
            loc_vp[0] = VperpOut[0+3*ii]
            loc_vp[1] = VperpOut[1+3*ii]
            loc_vp[2] = VperpOut[2+3*ii]
            upscaDp = loc_us[0]*loc_ds[0] + loc_us[1]*loc_ds[1]
            upar2 = loc_us[0]*loc_us[0] + loc_us[1]*loc_us[1]
            Dpar2 = loc_ds[0]*loc_ds[0] + loc_ds[1]*loc_ds[1]
            invDpar2 = 1./Dpar2
            # Prepare in case Forbid is True
            if Forbid0 and not Dpar2 > 0:
                Forbidbis = 0
            if Forbidbis:
                # Compute coordinates of the 2 points where the tangents touch
                # the inner circle
                L = Csqrt(Dpar2-rmin2)
                S1X = (rmin2*loc_ds[0]+val_rmin*loc_ds[1]*L)*invDpar2
                S1Y = (rmin2*loc_ds[1]-val_rmin*loc_ds[0]*L)*invDpar2
                S2X = (rmin2*loc_ds[0]-val_rmin*loc_ds[1]*L)*invDpar2
                S2Y = (rmin2*loc_ds[1]+val_rmin*loc_ds[0]*L)*invDpar2

            # Compute all solutions
            # Set tolerance value for us[2,ii]
            # EpsUz is the tolerated DZ across 20m (max Tokamak size)
            Crit2 = upar2*Crit2_base
            kpin_loc[0] = kPIn[ii]
            kpout_loc[0] = kPOut[ii]
            ind_loc[0] = IOut[2 + 3*ii]
            found_new = comp_inter_los_vpoly(loc_ds, loc_us,
                                             VPoly, VIn,
                                             Ns, lim_is_none,
                                             L0, L1,
                                             kpin_loc, kpout_loc,
                                             ind_loc, loc_vp,
                                             Forbidbis,
                                             upscaDp, upar2,
                                             Dpar2, invDpar2,
                                             S1X, S1Y, S2X, S2Y,
                                             Crit2, EpsUz, EpsVz, EpsA, EpsB,
                                             EpsPlane, True)
            if found_new:
                kPIn[ii]         = kpin_loc[0]
                kPOut[ii]        = kpout_loc[0]
                IOut[2+3*ii]     = ind_loc[0]
                IOut[0+3*ii]     = 0
                IOut[1+3*ii]     = 0
                VperpOut[0+3*ii] = loc_vp[0]
                VperpOut[1+3*ii] = loc_vp[1]
                VperpOut[2+3*ii] = loc_vp[2]
            else:
                kPIn[ii]         = Cnan
                kPOut[ii]        = Cnan
                IOut[2+3*ii]     = -1000000
                IOut[0+3*ii]     = 0
                IOut[1+3*ii]     = 0
                VperpOut[0+3*ii] = Cnan
                VperpOut[1+3*ii] = Cnan
                VperpOut[2+3*ii] = Cnan
        # If there are Struct, call the same function
        # Structural optimzation : do everything in one big for loop and only
        # keep the relevant points (to save memory)
        if LSPoly is not None:
            
            for ind_tmp in range(num_los):
                ind_lim_data = 0
                # We get the last kpout:
                kpout_jj = kPOut[ind_tmp]
                kpin_loc[0] = kpout_jj
                ind_loc[0] = IOut[2+3*ind_tmp]
                loc_ds[0] = Ds[0, ind_tmp]
                loc_ds[1] = Ds[1, ind_tmp]
                loc_ds[2] = Ds[2, ind_tmp]
                loc_us[0] = dus[0, ind_tmp]
                loc_us[1] = dus[1, ind_tmp]
                loc_us[2] = dus[2, ind_tmp]
                loc_vp[0] = 0.
                loc_vp[1] = 0.
                loc_vp[2] = 0.
                last_pout[0] = kpout_jj * loc_us[0] + loc_ds[0]
                last_pout[1] = kpout_jj * loc_us[1] + loc_ds[1]
                last_pout[2] = kpout_jj * loc_us[2] + loc_ds[2]
                compute_inv_and_sign(loc_us, sign_ray, invr_ray)
                # computing sclar prods for Ray and rmin values
                if Forbid:
                    Forbid0, Forbidbis = 1, 1
                else:
                    Forbid0, Forbidbis = 0, 0
                upscaDp = loc_us[0]*loc_ds[0] + loc_us[1]*loc_ds[1]
                upar2   = loc_us[0]*loc_us[0] + loc_us[1]*loc_us[1]
                Dpar2   = loc_ds[0]*loc_ds[0] + loc_ds[1]*loc_ds[1]
                invDpar2 = 1./Dpar2
                Crit2 = upar2*Crit2_base
                # Prepare in case Forbid is True
                if Forbid0 and not Dpar2>0:
                    Forbidbis = 0
                if Forbidbis:
                    # Compute coordinates of the 2 points where the tangents touch
                    # the inner circle
                    rmin2 = val_rmin*val_rmin
                    L = Csqrt(Dpar2-rmin2)
                    S1X = (rmin2*loc_ds[0]+val_rmin*loc_ds[1]*L)*invDpar2
                    S1Y = (rmin2*loc_ds[1]-val_rmin*loc_ds[0]*L)*invDpar2
                    S2X = (rmin2*loc_ds[0]-val_rmin*loc_ds[1]*L)*invDpar2
                    S2Y = (rmin2*loc_ds[1]+val_rmin*loc_ds[0]*L)*invDpar2

                for ii in range(len_lspoly):
                    #lspoly_view = LSPoly[ii]
                    #nvert = lspoly_view.shape[1]
                    nvert = len(LSPoly[ii][0])
                    for jj in range(lSnLim[ii]):
                        bounds[0] = lbounds[ind_lim_data*6]
                        bounds[1] = lbounds[ind_lim_data*6 + 1]
                        bounds[2] = lbounds[ind_lim_data*6 + 2]
                        bounds[3] = lbounds[ind_lim_data*6 + 3]
                        bounds[4] = lbounds[ind_lim_data*6 + 4]
                        bounds[5] = lbounds[ind_lim_data*6 + 5]
                        # if ind_tmp == 0:
                        #     for kk in range(6):
                        #         print("+ For ii = ", ii, " jj =", jj, "kk = ", kk, " bounds = ", bounds[kk])
                        L0 = langles[ind_lim_data*2]
                        L1 = langles[ind_lim_data*2 + 1]
                        lim_is_none = llim_ves[ind_lim_data]
                        ind_lim_data = 1 + ind_lim_data

                        # We test if it is really necessary to compute the inter:
                        # We check if the ray intersects the bounding box
                        inter_bbox = ray_intersects_abba_bbox(sign_ray, invr_ray, bounds, loc_ds)
                        if not inter_bbox:
                            continue

                        # We check that the bounding box is not "behind" the last POut encountered
                        inter_bbox = ray_intersects_abba_bbox(sign_ray, invr_ray, bounds, last_pout)
                        if inter_bbox:
                            continue

                        # We compute new values
                        found_new_kout = comp_inter_los_vpoly(loc_ds, loc_us,
                                                              LSPoly[ii],
                                                              LSVIn[ii], nvert,
                                                              lim_is_none, L0, L1,
                                                              kpin_loc, kpout_loc, ind_loc,
                                                              loc_vp,
                                                              Forbidbis,
                                                              upscaDp, upar2, Dpar2, invDpar2,
                                                              S1X, S1Y, S2X, S2Y,
                                                              Crit2, EpsUz, EpsVz,
                                                              EpsA, EpsB,
                                                              EpsPlane, False)
                        if found_new_kout :
                            kPOut[ind_tmp] = kpin_loc[0]
                            VperpOut[0+3*ind_tmp] = loc_vp[0]
                            VperpOut[1+3*ind_tmp] = loc_vp[1]
                            VperpOut[2+3*ind_tmp] = loc_vp[2]
                            IOut[2+3*ind_tmp] = ind_loc[0]
                            IOut[0+3*ind_tmp] = 1+ii
                            IOut[1+3*ind_tmp] = jj
                            last_pout[0] = kPOut[ind_tmp] * loc_us[0] + loc_ds[0]
                            last_pout[1] = kPOut[ind_tmp] * loc_us[1] + loc_ds[1]
                            last_pout[2] = kPOut[ind_tmp] * loc_us[2] + loc_ds[2]

    PyMem_Free(lbounds)
    PyMem_Free(langles)

    # arr_kpin  = pointer_to_numpy_array_double(kPIn, num_los)
    # arr_kpout = pointer_to_numpy_array_double(kPOut, num_los)
    # arr_vperp = pointer_to_numpy_array_double(VperpOut, 3*num_los)
    # arr_iout  = pointer_to_numpy_array_int(IOut, 3*num_los)
    # PyMem_Free(kPIn)
    # PyMem_Free(kPOut)
    # PyMem_Free(IOut)
    # PyMem_Free(VperpOut)
    # return arr_kpin, arr_kpout, arr_vperp, arr_iout

    # kpin_view = kPIn
    # kpOut_view = kPOut
    # vperp_view = VperpOut
    # ind_view = IOut
          
    return np.asarray(kPIn), np.asarray(kPOut), np.asarray(VperpOut), np.asarray(IOut)

cdef inline bint comp_inter_los_vpoly(double [3] Ds, double [3] us,
                                double [:,::1] VPoly, double [:,::1] vIn,
                                int vin_shape,
                                bint lim_is_none, double L0, double L1,
                                double[1] kpin_loc, double[1] kpout_loc, int[1] ind_loc, double[3] vperpin,
                                bint Forbidbis, double upscaDp, double upar2, double Dpar2, double invDpar2,
                                double S1X, double S1Y, double S2X, double S2Y,
                                double Crit2, double EpsUz,
                                double EpsVz, double EpsA,
                                double EpsB, double EpsPlane, bint struct_is_ves) nogil:
    cdef int jj
    cdef int indin=0, Done=0, indout=0
    cdef bint inter_bbox
    cdef double kout, kin
    cdef double sca=0., sca0=0., sca1=0., sca2=0.
    cdef double q, C, delta, sqd, k, sol0, sol1, phi=0.
    cdef double v0, v1, A, B, ephiIn0, ephiIn1
    cdef double SOut1, SOut0
    cdef double SIn1, SIn0
    cdef double res_kin = kpin_loc[0]
    cdef double[3] opp_dir
    cdef double invupar2
    cdef double invuz
    cdef double cosl0, cosl1, sinl0, sinl1
    ################
    # Computing some useful values
    cosl0 = Ccos(L0)
    cosl1 = Ccos(L1)
    sinl0 = Csin(L0)
    sinl1 = Csin(L1)
    invupar2 = 1./upar2
    invuz = 1./us[2]
    # Compute all solutions
    # Set tolerance value for us[2,ii]
    # EpsUz is the tolerated DZ across 20m (max Tokamak size)
    kin = 1.e12
    kout = 1.e12
    Done = 0
    # Case with horizontal semi-line
    if us[2]*us[2]<Crit2:
        for jj in range(vin_shape):
            # Solutions exist only in the case with non-horizontal
            # segment (i.e.: cone, not plane)
            if Cabs(VPoly[1,jj+1] - VPoly[1,jj]) > EpsVz:
                q = (Ds[2]-VPoly[1,jj]) / (VPoly[1,jj+1]-VPoly[1,jj])
                # The intersection must stand on the segment
                if q>=0 and q<1:
                    C = q*q*(VPoly[0,jj+1]-VPoly[0,jj])**2 + \
                        2.*q*VPoly[0,jj]*(VPoly[0,jj+1]-VPoly[0,jj]) + \
                        VPoly[0,jj]*VPoly[0,jj]
                    delta = upscaDp*upscaDp - upar2*(Dpar2-C)
                    if delta>0.:
                        sqd = Csqrt(delta)
                        # The intersection must be on the semi-line
                        # (i.e.: k>=0)
                        # First solution
                        if -upscaDp - sqd >=0:
                            k = (-upscaDp - sqd)*invupar2
                            sol0, sol1 = Ds[0] + k*us[0], \
                                         Ds[1] + k*us[1]
                            if Forbidbis:
                                sca0 = (sol0-S1X)*Ds[0] + \
                                       (sol1-S1Y)*Ds[1]
                                sca1 = (sol0-S1X)*S1X + (sol1-S1Y)*S1Y
                                sca2 = (sol0-S2X)*S2X + (sol1-S2Y)*S2Y
                            if not Forbidbis or (Forbidbis and not
                                                 (sca0<0 and sca1<0 and
                                                  sca2<0)):
                                # Get the normalized perpendicular vector
                                # at intersection
                                phi = Catan2(sol1,sol0)
                                # Check sol inside the Lim
                                if lim_is_none or (not lim_is_none and
                                                   ((L0<L1 and L0<=phi and
                                                     phi<=L1)
                                                    or (L0>L1 and
                                                        (phi>=L0 or
                                                         phi<=L1)))):
                                    # Get the scalar product to determine
                                    # entry or exit point
                                    sca = Ccos(phi)*vIn[0,jj]*us[0] + \
                                          Csin(phi)*vIn[0,jj]*us[1] + \
                                          vIn[1,jj]*us[2]
                                    if sca<=0 and k<kout:
                                        kout = k
                                        Done = 1
                                        indout = jj
                                    elif sca>=0 and k<min(kin,kout):
                                        kin = k
                                        indin = jj

                        # Second solution
                        if -upscaDp + sqd >=0:
                            k = (-upscaDp + sqd)*invupar2
                            sol0, sol1 = Ds[0] + k*us[0], Ds[1] \
                                         + k*us[1]
                            if Forbidbis:
                                sca0 = (sol0-S1X)*Ds[0] + \
                                       (sol1-S1Y)*Ds[1]
                                sca1 = (sol0-S1X)*S1X + (sol1-S1Y)*S1Y
                                sca2 = (sol0-S2X)*S2X + (sol1-S2Y)*S2Y
                            if not Forbidbis or (Forbidbis and not
                                                 (sca0<0 and sca1<0 and
                                                  sca2<0)):
                                # Get the normalized perpendicular vector
                                # at intersection
                                phi = Catan2(sol1,sol0)
                                if lim_is_none or (not lim_is_none and
                                                   ((L0<L1 and L0<=phi and
                                                     phi<=L1) or
                                                    (L0>L1 and
                                                     (phi>=L0 or phi<=L1))
                                                   )):
                                    # Get the scalar product to determine
                                    # entry or exit point
                                    sca = Ccos(phi)*vIn[0,jj]*us[0] + \
                                          Csin(phi)*vIn[0,jj]*us[1] + \
                                          vIn[1,jj]*us[2]
                                    if sca<=0 and k<kout:
                                        kout = k
                                        Done = 1
                                        indout = jj
                                    elif sca>=0 and k<min(kin,kout):
                                        kin = k
                                        indin = jj

    # More general non-horizontal semi-line case
    else:
        for jj in range(vin_shape):
            v0, v1 = VPoly[0,jj+1]-VPoly[0,jj], VPoly[1,jj+1]-VPoly[1,jj]
            A = v0*v0 - upar2*(v1*invuz)*(v1*invuz)
            B = VPoly[0,jj]*v0 + v1*(Ds[2]-VPoly[1,jj])*upar2*invuz*invuz - upscaDp*v1*invuz
            C = -upar2*(Ds[2]-VPoly[1,jj])**2*invuz*invuz + 2.*upscaDp*(Ds[2]-VPoly[1,jj])*invuz - Dpar2 + VPoly[0,jj]*VPoly[0,jj]

            if A*A<EpsA*EpsA and B*B>EpsB*EpsB:
                q = -C/(2.*B)
                if q>=0. and q<1.:
                    k = (q*v1 - (Ds[2]-VPoly[1,jj]))*invuz
                    if k>=0:
                        sol0, sol1 = Ds[0] + k*us[0], Ds[1] + k*us[1]
                        if Forbidbis:
                            sca0 = (sol0-S1X)*Ds[0] + (sol1-S1Y)*Ds[1]
                            sca1 = (sol0-S1X)*S1X + (sol1-S1Y)*S1Y
                            sca2 = (sol0-S2X)*S2X + (sol1-S2Y)*S2Y
                            if sca0<0 and sca1<0 and sca2<0:
                                continue
                        # Get the normalized perpendicular vector at intersection
                        phi = Catan2(sol1,sol0)
                        if lim_is_none or (not lim_is_none and ((L0<L1 and L0<=phi and phi<=L1) or (L0>L1 and (phi>=L0 or phi<=L1)))):
                            # Get the scalar product to determine entry or exit point
                            sca = Ccos(phi)*vIn[0,jj]*us[0] + Csin(phi)*vIn[0,jj]*us[1] + vIn[1,jj]*us[2]
                            if sca<=0 and k<kout:
                                kout = k
                                Done = 1
                                indout = jj
                            elif sca>=0 and k<min(kin,kout):
                                kin = k
                                indin = jj

            elif A*A>=EpsA*EpsA and B*B>A*C:
                sqd = Csqrt(B*B-A*C)
                # First solution
                q = (-B + sqd)/A
                if q>=0. and q<1.:
                    k = (q*v1 - (Ds[2]-VPoly[1,jj]))*invuz
                    if k>=0.:
                        sol0, sol1 = Ds[0] + k*us[0], Ds[1] + k*us[1]
                        if Forbidbis:
                            sca0 = (sol0-S1X)*Ds[0] + (sol1-S1Y)*Ds[1]
                            sca1 = (sol0-S1X)*S1X + (sol1-S1Y)*S1Y
                            sca2 = (sol0-S2X)*S2X + (sol1-S2Y)*S2Y
                        if not Forbidbis or (Forbidbis and not (sca0<0 and sca1<0 and sca2<0)):
                            # Get the normalized perpendicular vector at intersection
                            phi = Catan2(sol1,sol0)
                            if lim_is_none or (not lim_is_none and ((L0<L1 and L0<=phi and phi<=L1) or (L0>L1 and (phi>=L0 or phi<=L1)))):
                                # Get the scalar product to determine entry or exit point
                                sca = Ccos(phi)*vIn[0,jj]*us[0] + Csin(phi)*vIn[0,jj]*us[1] + vIn[1,jj]*us[2]
                                if sca<=0 and k<kout:
                                    kout = k
                                    Done = 1
                                    indout = jj
                                elif sca>=0 and k<min(kin,kout):
                                    kin = k
                                    indin = jj

                # Second solution
                q = (-B - sqd)/A
                if q>=0. and q<1.:
                    k = (q*v1 - (Ds[2]-VPoly[1,jj]))*invuz

                    if k>=0.:
                        sol0, sol1 = Ds[0] + k*us[0], Ds[1] + k*us[1]
                        if Forbidbis:
                            sca0 = (sol0-S1X)*Ds[0] + (sol1-S1Y)*Ds[1]
                            sca1 = (sol0-S1X)*S1X + (sol1-S1Y)*S1Y
                            sca2 = (sol0-S2X)*S2X + (sol1-S2Y)*S2Y
                        if not Forbidbis or (Forbidbis and not (sca0<0 and sca1<0 and sca2<0)):
                            # Get the normalized perpendicular vector at intersection
                            phi = Catan2(sol1,sol0)
                            if lim_is_none or (not lim_is_none and ((L0<L1 and L0<=phi and phi<=L1) or (L0>L1 and (phi>=L0 or phi<=L1)))):
                                # Get the scalar product to determine entry or exit point
                                sca = Ccos(phi)*vIn[0,jj]*us[0] + Csin(phi)*vIn[0,jj]*us[1] + vIn[1,jj]*us[2]
                                if sca<=0 and k<kout:
                                    kout = k
                                    Done = 1
                                    indout = jj
                                elif sca>=0 and k<min(kin,kout):
                                    kin = k
                                    indin = jj

    if not lim_is_none:
        ephiIn0 = -sinl0
        ephiIn1 =  cosl0
        if Cabs(us[0]*ephiIn0+us[1]*ephiIn1)>EpsPlane:
            k = -(Ds[0]*ephiIn0+Ds[1]*ephiIn1)/(us[0]*ephiIn0+us[1]*ephiIn1)
            if k>=0:
                # Check if in VPoly
                sol0 = (Ds[0] + k*us[0]) * cosl0 + (Ds[1] + k*us[1]) * sinl0
                sol1 =  Ds[2] + k*us[2]
                inter_bbox = is_point_in_path(vin_shape, VPoly[0,...], VPoly[1,...], sol0, sol1)
                if inter_bbox:
                    # Check PIn (POut not possible for limited torus)
                    sca = us[0]*ephiIn0 + us[1]*ephiIn1
                    if sca<=0 and k<kout:
                        kout = k
                        Done = 1
                        indout = -1
                    elif sca>=0 and k<min(kin,kout):
                        kin = k
                        indin = -1

        ephiIn0 =  sinl1
        ephiIn1 = -cosl1
        if Cabs(us[0]*ephiIn0+us[1]*ephiIn1)>EpsPlane:
            k = -(Ds[0]*ephiIn0+Ds[1]*ephiIn1)/(us[0]*ephiIn0+us[1]*ephiIn1)
            if k>=0:
                sol0, sol1 = (Ds[0]+k*us[0])*cosl1 + (Ds[1]+k*us[1])*sinl1, Ds[2]+k*us[2]
                # Check if in VPoly
                #if path_poly_t.contains_point([sol0,sol1], transform=None, radius=0.0):
                # if ray_tracing(VPoly, sol0, sol1):
                inter_bbox = is_point_in_path(vin_shape, VPoly[0,...], VPoly[1,...], sol0, sol1)
                if inter_bbox:
                    # Check PIn (POut not possible for limited torus)
                    sca = us[0]*ephiIn0 + us[1]*ephiIn1
                    if sca<=0 and k<kout:
                        kout = k
                        Done = 1
                        indout = -2
                    elif sca>=0 and k<min(kin,kout):
                        kin = k
                        indin = -2

    if Done==1:
        if struct_is_ves :
            kpout_loc[0] = kout
            if indout==-1:
                vperpin[0] = -sinl0
                vperpin[1] = cosl0
                vperpin[2] = 0.
            elif indout==-2:
                vperpin[0] = sinl1
                vperpin[1] = -cosl1
                vperpin[2] = 0.
            else:
                SOut0 = Ds[0] + kout*us[0]
                SOut1 = Ds[1] + kout*us[1]
                phi = Catan2(SOut1,SOut0)
                vperpin[0] = Ccos(phi)*vIn[0,indout]
                vperpin[1] = Csin(phi)*vIn[0,indout]
                vperpin[2] = vIn[1,indout]
            ind_loc[0] = indout
            if kin<kout:
                kpin_loc[0] = kin

        elif kin<kout and kin < res_kin:
            kpin_loc[0] = kin
            if indin==-1:
                vperpin[0] = sinl0
                vperpin[1] = -cosl0
                vperpin[2] = 0.
            elif indin==-2:
                vperpin[0] = -sinl1
                vperpin[1] = cosl1
                vperpin[2] = 0.
            else:
                SIn0 = Ds[0] + kin*us[0]
                SIn1 = Ds[1] + kin*us[1]
                phi = Catan2(SIn1,SIn0)
                vperpin[0] = -Ccos(phi)*vIn[0,indin]
                vperpin[1] = -Csin(phi)*vIn[0,indin]
                vperpin[2] = -vIn[1,indin]
            ind_loc[0] = indin

    return res_kin != kpin_loc[0]

cdef inline void compute_inv_and_sign(const double[3] us,
                                      int[3] sign,
                                      double[3] inv_direction) nogil:
    cdef int t0 = 1000000
    # computing sign and direction
    for  ii in range(3):
        if us[ii]*us[ii] < _VSMALL:
            inv_direction[ii] = t0
        else:
            inv_direction[ii] = 1./us[ii]
        if us[ii] < 0.:
            sign[ii] = 1
        else:
            sign[ii] = 0

    return

cdef inline bint ray_intersects_abba_bbox(const int[3] sign,
                                          const double[3] inv_direction,
                                          const double[6] bounds,
                                          const double[3] ds) nogil:
    """
    bounds = [3d coords of lowerleftback point of bounding box,
              3d coords of upperrightfront point of bounding box]
    ds = [3d coords of origin of ray]
    returns True if ray intersects bounding box, else False
    """
    cdef double tmin, tmax, tymin, tymax
    cdef double tzmin, tzmax
    cdef int t0 = 1000000
    cdef bint res

    # computing intersection
    tmin = (bounds[sign[0]*3] - ds[0]) * inv_direction[0];
    tmax = (bounds[(1-sign[0])*3] - ds[0]) * inv_direction[0];
    tymin = (bounds[(sign[1])*3 + 1] - ds[1]) * inv_direction[1];
    tymax = (bounds[(1-sign[1])*3+1] - ds[1]) * inv_direction[1];
    if ( (tmin > tymax) or (tymin > tmax) ):
        return 0
    if (tymin > tmin):
        tmin = tymin
    if (tymax < tmax):
        tmax = tymax
    tzmin = (bounds[(sign[2])*3+2] - ds[2]) * inv_direction[2]
    tzmax = (bounds[(1-sign[2])*3+2] - ds[2]) * inv_direction[2]
    if ( (tmin > tzmax) or (tzmin > tmax) ):
        return 0
    if (tzmin > tmin):
        tmin = tzmin
    if (tzmax < tmax):
        tmax = tzmax

    res = (tmin < t0) and (tmax > -t0)
    if (tmin < 0) :
        return 0
    return  res


cdef inline bint is_point_in_path(int nvert, double[:] vertx, double[:] verty, double testx, double testy) nogil:
    cdef int i
    cdef bint c = 0
    for i in range(nvert):
        if ( ((verty[i]>testy) != (verty[i+1]>testy)) and
            (testx < (vertx[i+1]-vertx[i]) * (testy-verty[i]) / (verty[i+1]-verty[i]) + vertx[i]) ):
            c = not c
    return c

# cdef inline void Calc_LOS_PInOut_Tor(double [:,::1] Ds, double [:,::1] us,
#                                      double [:,::1] VPoly, double [:,::1] vIn,
#                                      double[:] kPIn_view, double[:] kPOut_view,
#                                      double[:] VperpOut_view, int[:] IOut_view,
#                                      int Nl,
#                                      double Rmin, bint lim_is_none, double L0, double L1,
#                                      bint Forbid,  double EpsUz,
#                                      double EpsVz, double EpsA,
#                                      double EpsB,  double EpsPlane):

#     cdef int ii, jj, Ns=vIn.shape[1]
#     cdef double upscaDp, upar2, Dpar2, Crit2, kout, kin, invDpar2
#     cdef int indout=0, Done=0
#     cdef double L=0., S1X=0., S1Y=0., S2X=0., S2Y=0., sca=0., sca0=0., sca1=0., sca2=0.
#     cdef double q, C, delta, sqd, k, sol0, sol1, phi=0., rmin2
#     cdef double v0, v1, A, B, ephiIn0, ephiIn1, Crit2_base = EpsUz*EpsUz/400.
#     cdef double[3] loc_ds
#     cdef double[3] loc_us
#     cdef double[3] loc_vp
#     cdef double[1] kpin_loc
#     cdef double[1] kpout_loc
#     cdef int[1] ind_loc
#     cdef double SOut1, SOut0
#     cdef int Forbidbis, Forbid0
#     cdef bint found_new

#     ################
#     # Compute
#     if Forbid:
#         Forbid0, Forbidbis = 1, 1
#     else:
#         Forbid0, Forbidbis = 0, 0
#     for ii in range(0,Nl):
#         loc_us[0] = us[0,ii]
#         loc_us[1] = us[1,ii]
#         loc_us[2] = us[2,ii]
#         loc_ds[0] = Ds[0,ii]
#         loc_ds[1] = Ds[1,ii]
#         loc_ds[2] = Ds[2,ii]
#         loc_vp[0] = VperpOut_view[0+3*ii]
#         loc_vp[1] = VperpOut_view[1+3*ii]
#         loc_vp[2] = VperpOut_view[2+3*ii]
#         upscaDp = loc_us[0]*loc_ds[0] + loc_us[1]*loc_ds[1]
#         upar2 = loc_us[0]*loc_us[0] + loc_us[1]*loc_us[1]
#         Dpar2 = loc_ds[0]*loc_ds[0] + loc_ds[1]*loc_ds[1]
#         invDpar2 = 1./Dpar2
#         # Prepare in case Forbid is True
#         if Forbid0 and not Dpar2>0:
#             Forbidbis = 0
#         if Forbidbis:
#             # Compute coordinates of the 2 points where the tangents touch
#             # the inner circle
#             rmin2 = Rmin*Rmin
#             L = Csqrt(Dpar2-rmin2)
#             S1X = (rmin2*loc_ds[0]+Rmin*loc_ds[1]*L)*invDpar2
#             S1Y = (rmin2*loc_ds[1]-Rmin*loc_ds[0]*L)*invDpar2
#             S2X = (rmin2*loc_ds[0]-Rmin*loc_ds[1]*L)*invDpar2
#             S2Y = (rmin2*loc_ds[1]+Rmin*loc_ds[0]*L)*invDpar2

#         # Compute all solutions
#         # Set tolerance value for us[2,ii]
#         # EpsUz is the tolerated DZ across 20m (max Tokamak size)
#         Crit2 = upar2*Crit2_base
#         kpin_loc[0]  = kPIn_view[ii]
#         kpout_loc[0] = kPOut_view[ii]
#         ind_loc[0] = IOut_view[2 + 3*ii]
#         found_new = comp_inter_los_vpoly(loc_ds, loc_us, VPoly, vIn, Ns, lim_is_none,
#                                          L0, L1, kpin_loc, kpout_loc, ind_loc, loc_vp,
#                                          Forbidbis, upscaDp, upar2, Dpar2, invDpar2,
#                                          S1X, S1Y, S2X, S2Y, Crit2, EpsUz, EpsVz, EpsA, EpsB,
#                                          EpsPlane, True)
#         if found_new:
#             kPIn_view[ii]         = kpin_loc[0]
#             kPOut_view[ii]        = kpout_loc[0]
#             IOut_view[2+3*ii]     = ind_loc[0]
#             IOut_view[0+3*ii]     = 0
#             IOut_view[1+3*ii]     = 0
#             VperpOut_view[0+3*ii] = loc_vp[0]
#             VperpOut_view[1+3*ii] = loc_vp[1]
#             VperpOut_view[2+3*ii] = loc_vp[2]

#         else:
#             kPIn_view[ii]         = Cnan
#             kPOut_view[ii]        = Cnan
#             IOut_view[2+3*ii]     = -1000000
#             IOut_view[0+3*ii]     = 0
#             IOut_view[1+3*ii]     = 0
#             VperpOut_view[0+3*ii] = Cnan
#             VperpOut_view[1+3*ii] = Cnan
#             VperpOut_view[2+3*ii] = Cnan

#     return



cdef inline void compute_bbox_extr(int nvert, double[:,::1] vert,
                                   double[6] bounds) nogil:
    cdef int ii
    cdef double rmax=vert[0,0], zmin=vert[1,0], zmax=vert[1,0]
    cdef double tmp_val
    for ii in range(1, nvert):
        tmp_val = vert[0,ii]
        if tmp_val > rmax:
            rmax = tmp_val
        tmp_val = vert[1,ii]
        if tmp_val > zmax:
            zmax = tmp_val
        elif tmp_val < zmin:
            zmin = tmp_val
    bounds[0] = -rmax
    bounds[1] = -rmax
    bounds[2] = zmin
    bounds[3] = rmax
    bounds[4] = rmax
    bounds[5] = zmax
    return


cdef inline void compute_bbox_lim(int nvert, double[:,::1] vert,
                                  double[6] bounds, double lmin, double lmax) nogil:
    cdef int ii
    cdef double toto=100000.
    cdef double xmin=toto, xmax=-toto
    cdef double ymin=toto, ymax=-toto
    cdef double zmin=toto, zmax=-toto
    cdef double cos_min = Ccos(lmin)
    cdef double sin_min = Csin(lmin)
    cdef double cos_max = Ccos(lmax)
    cdef double sin_max = Csin(lmax)
    cdef double[3] temp

    for ii in range(nvert):
        temp[0] = vert[0, ii]
        temp[1] = vert[1, ii]
        coordshift_simple1d(temp, in_is_cartesian=False, CrossRef=1.,
                          cos_phi=cos_min, sin_phi=sin_min)
        if xmin > temp[0]:
            xmin = temp[0]
        if xmax < temp[0]:
            xmax = temp[0]
        if ymin > temp[1]:
            ymin = temp[1]
        if ymax < temp[1]:
            ymax = temp[1]
        if zmin > temp[2]:
            zmin = temp[2]
        if zmax < temp[2]:
            zmax = temp[2]
        temp[0] = vert[0, ii]
        temp[1] = vert[1, ii]
        coordshift_simple1d(temp, in_is_cartesian=False, CrossRef=1.,
                          cos_phi=cos_max, sin_phi=sin_max)
        if xmin > temp[0]:
            xmin = temp[0]
        if xmax < temp[0]:
            xmax = temp[0]
        if ymin > temp[1]:
            ymin = temp[1]
        if ymax < temp[1]:
            ymax = temp[1]
        if zmin > temp[2]:
            zmin = temp[2]
        if zmax < temp[2]:
            zmax = temp[2]

    bounds[0] = xmin
    bounds[1] = ymin
    bounds[2] = zmin
    bounds[3] = xmax
    bounds[4] = ymax
    bounds[5] = zmax
    return



cdef inline void coordshift_simple1d(double[3] pts, bint in_is_cartesian=True,
                                     double CrossRef=0., double cos_phi=0.,
                                     double sin_phi=0.) nogil:

    cdef double x, y, z
    cdef double r, p
    if in_is_cartesian:
        if CrossRef==0.:
            x = pts[0]
            y = pts[1]
            z = pts[2]
            pts[0] = Csqrt(x*x+y*y)
            pts[1] = z
            pts[2] = Catan2(y,x)
        else:
            x = pts[0]
            y = pts[1]
            z = pts[2]
            pts[0] = Csqrt(x*x+y*y)
            pts[1] = z
            pts[2] = CrossRef
    else:
        if CrossRef==0.:
            r = pts[0]
            z = pts[1]
            p = pts[2]
            pts[0] = r*Ccos(p)
            pts[1] = r*Csin(p)
            pts[2] = z
        else:
            r = pts[0]
            z = pts[1]
            pts[0] = r*cos_phi
            pts[1] = r*sin_phi
            pts[2] = z
    return
