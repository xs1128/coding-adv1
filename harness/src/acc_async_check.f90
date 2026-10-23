! P3 prerequisites on NVHPC, checked on a compute node (seconds):
!  1. acc_set_cuda_stream(acc_async_noval, <sync stream>) puts the default async queue on the synchronous stream,
!     so async and synchronous work run in issue order.
!  2. `update device(s) async` from a host scalar that is changed right after the directive still delivers the value
!     it had at enqueue (the runtime stages pageable data before returning).
!  3. Cost per (scalar update + small kernel): synchronous vs async.
program acc_async_check
    use openacc
    implicit none
    integer, parameter :: n = 20000, nb = 2**24
    integer :: s, i, bad
    integer, allocatable :: a(:)
    real(8), allocatable :: b(:), c(:)
    integer(8) :: t0, t1, rate
    !$acc declare create(s)
    allocate (a(n), b(nb), c(nb))
    !$acc enter data create(a, b, c)
    print '(a,i0,a,i0)', 'sync stream ', loc_stream(acc_async_sync), ' noval stream ', loc_stream(acc_async_noval)
    call acc_set_cuda_stream(acc_async_noval, acc_get_cuda_stream(acc_async_sync))
    print '(a,i0)', 'noval stream after alias ', loc_stream(acc_async_noval)

    ! 2: staged scalar updates
    do i = 1, n
        s = i
        !$acc update device(s) async
        !$acc serial present(a) async
        a(i) = s
        !$acc end serial
        s = -1
    end do
    !$acc wait
    !$acc update host(a)
    bad = count(a /= [(i, i=1, n)])
    print '(a,i0,a,i0)', 'staged update: mismatches ', bad, ' of ', n

    ! 1: an async producer followed by a synchronous consumer with no explicit wait
    !$acc parallel loop present(b) async
    do i = 1, nb
        b(i) = sqrt(real(i, 8))**2 + sin(real(i, 8))**2 + cos(real(i, 8))**2
    end do
    !$acc parallel loop present(b, c)
    do i = 1, nb
        c(i) = b(i)
    end do
    !$acc update host(c)
    bad = count(abs(c - [(real(i, 8) + 1d0, i=1, nb)]) > 1d-6*real(nb, 8))
    print '(a,i0,a,i0)', 'ordering async->sync: mismatches ', bad, ' of ', nb

    ! 3: cost per update+kernel
    call system_clock(t0, rate)
    do i = 1, n
        s = i
        !$acc update device(s)
        !$acc serial present(a)
        a(i) = s
        !$acc end serial
    end do
    call system_clock(t1)
    print '(a,f8.2,a)', 'sync  update+kernel: ', 1d6*real(t1 - t0, 8)/rate/n, ' us'
    call system_clock(t0)
    do i = 1, n
        s = i
        !$acc update device(s) async
        !$acc serial present(a) async
        a(i) = s
        !$acc end serial
    end do
    !$acc wait
    call system_clock(t1)
    print '(a,f8.2,a)', 'async update+kernel: ', 1d6*real(t1 - t0, 8)/rate/n, ' us'
contains
    integer(8) function loc_stream(q)
        integer(acc_handle_kind), intent(in) :: q
        loc_stream = transfer(acc_get_cuda_stream(q), 0_8)
    end function
end program
