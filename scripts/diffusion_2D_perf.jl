using AMDGPU, ImplicitGlobalGrid, Plots, Printf

function diffusion_step!(T2, T, Cp, lam, dt, _dx, _dy)
    ix = (workgroupIdx().x - 1) * workgroupDim().x + workitemIdx().x
    iy = (workgroupIdx().y - 1) * workgroupDim().y + workitemIdx().y
    nx, ny = size(T2)
    if (ix>1 && ix<nx && iy>1 && iy<ny)
        @inbounds T2[ix,iy] = T[ix,iy] + dt*(Cp[ix,iy]*(
                              - ((-lam*(T[ix+1,iy] - T[ix,iy])*_dx) - (-lam*(T[ix,iy] - T[ix-1,iy])*_dx))*_dx
                              - ((-lam*(T[ix,iy+1] - T[ix,iy])*_dy) - (-lam*(T[ix,iy] - T[ix,iy-1])*_dy))*_dy ))
    end
    return
end

@views function diffusion2D(;do_vis=false)
    # Physics
    lx, ly  = 10.0, 10.0                                # Length of domain in dimensions x, y and z
    lam     = 1.0                                       # Thermal conductivity
    Cp0     = 1.0
    # Numerics
    fact    = 12
    nx, ny  = fact*1024, fact*1024                      # number of grid points
    threads = (32, 8)
    grid    = (nx, ny)
    nt      = 1e3                                       # Number of time steps
    me, dims, nprocs, coords, comm_cart = init_global_grid(nx, ny, 1) # Initialize the implicit global grid
    println("Process $me selecting device $(AMDGPU.device())")
    dx, dy  = lx/nx_g(), ly/ny_g()                      # Space step in dimension x
    _dx,_dy = 1.0/dx, 1.0/dy
    dt      = min(dx*dx,dy*dy)*Cp0/lam/4.1              # Time step for the 3D Heat diffusion
    # Array initializations
    Cp      = Cp0.*AMDGPU.ones(Float64, nx, ny)
    T       =            zeros(Float64, nx, ny)
    # Initial conditions
    T       = ROCArray([exp(-(x_g(ix,dx,T)+dx/2 -lx/2)^2 -(y_g(iy,dy,T)+dy/2 -ly/2)^2) for ix=1:size(T,1), iy=1:size(T,2)])
    T2      = copy(T)
    # visu
    if do_vis
        if (me==0) gr(); ENV["GKSwstype"]="nul"; !ispath("../output") && mkdir("../output"); end
        nx_v = (nx-2)*dims[1]
        ny_v = (ny-2)*dims[2]
        T_v  = zeros(nx_v, ny_v)
        T_nh = zeros(nx-2, ny-2)
    end
    # Time loop
    me==0 && print("Starting the time loop 🚀...")
    for it = 1:nt
        if (it==11) tic() end
        wait( @roc groupsize=threads gridsize=grid diffusion_step!(T2, T, Cp, lam, dt, _dx, _dy) )
        T, T2 = T2, T
        update_halo!(T)
    end
    wtime = toc()
    me==0 && println("done")
    A_eff    = (2 + 1)/1e9*nx*ny*sizeof(Float64)  # Effective main memory access per iteration [GB] (Lower bound of required memory access: Te has to be read and written: 2 whole-array memaccess; Ci has to be read: : 1 whole-array memaccess)
    wtime_it = wtime/(nt-10)                      # Execution time per iteration [s]
    T_eff    = A_eff/wtime_it                     # Effective memory throughput [GB/s]
    me==0 && @printf("Executed %d steps in = %1.3e sec (@ T_eff = %1.2f GB/s) \n", nt, wtime, round(T_eff, sigdigits=3))
    if do_vis
        T_nh .= Array(T[2:end-1,2:end-1])
        gather!(T_nh, T_v)
        if (me==0) heatmap(transpose(T_v)); png("../output/Temp_perf_$(nprocs)_$(nx_g())_$(ny_g()).png"); end
    end
    finalize_global_grid()  # Finalize the implicit global grid
end

diffusion2D(;do_vis=false)
