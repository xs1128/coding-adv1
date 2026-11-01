! Does an OpenACC attach of a bounds-remapped Fortran pointer give the device the remapped lower bounds?
! Mirrors P7: flux_n(1)%vf(l)%sf(-1:,-1:,-1:) => flux_rsx_vf(:,:,:,l) after the original allocation is freed.
!   nvfortran -acc -gpu=cc90 remap_attach.f90 && ./a.out    -> prints PASS or FAIL
program remap_attach
    implicit none
    type sf_t
        real(8), pointer :: sf(:, :, :) => null()
    end type
    type vf_t
        type(sf_t), allocatable :: vf(:)
    end type
    integer, parameter :: m = 7, n = 5, p = 3, nv = 4, g = 4
    real(8), allocatable, target :: buf(:, :, :, :)
    type(vf_t), allocatable :: fl(:)
    real(8) :: s
    integer :: i, j, k, l, bad
    !$acc declare create(buf)

    allocate (buf(-1:m, -1:n, -1:p, 1:nv))
    allocate (fl(1:2))
    !$acc enter data create(fl)
    allocate (fl(1)%vf(1:nv))
    !$acc enter data create(fl(1)%vf)
    do l = 1, nv      ! the original, halo-sized allocation (as @:ALLOCATE does)
        allocate (fl(1)%vf(l)%sf(-g:m + g, -g:n + g, -g:p + g))
        !$acc enter data create(fl(1)%vf(l)%sf)
    end do
    do l = 1, nv      ! free it and alias the solver buffer instead
        !$acc exit data delete(fl(1)%vf(l)%sf)
        deallocate (fl(1)%vf(l)%sf)
        fl(1)%vf(l)%sf(-1:, -1:, -1:) => buf(:, :, :, l)
        !$acc enter data attach(fl(1)%vf(l)%sf)
    end do

    !$acc parallel loop collapse(4) present(buf)
    do l = 1, nv; do k = -1, p; do j = -1, n; do i = -1, m
        buf(i, j, k, l) = i + 100*j + 10000*k + 1000000*l
    end do; end do; end do; end do

    bad = 0
    !$acc parallel loop collapse(3) reduction(+:bad) present(fl)
    do k = 0, p; do j = 0, n; do i = 0, m
        !$acc loop seq
        do l = 1, nv
            s = fl(1)%vf(l)%sf(i - 1, j, k) + fl(1)%vf(l)%sf(i, j - 1, k - 1)
            if (s /= (i - 1 + 100*j + 10000*k + 1000000*l) + (i + 100*(j - 1) + 10000*(k - 1) + 1000000*l)) bad = bad + 1
        end do
    end do; end do; end do
    !$acc parallel loop collapse(2) present(fl)       ! device writes through the alias must land in buf
    do k = -1, p; do i = -1, m
        fl(1)%vf(2)%sf(i, n, k) = -1d0
    end do; end do
    !$acc update host(buf)
    if (any(buf(:, n, :, 2) /= -1d0)) bad = bad + 1
    if (bad == 0) then; print *, 'PASS'; else; print *, 'FAIL', bad; end if
end program
