#!/bin/bash
#SBATCH --nodes=32
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --time=5:00:00
#SBATCH --mem=4GB
#SBATCH --job-name=jacobi-weak-ln100-N1600-p256
#SBATCH --mail-type=END
#SBATCH --mail-user=cy1505@nyu.edu
#SBATCH --output=jacobi-weak-ln100-N1600-p256.out
#SBATCH --partition=c01_17

module purge
module load openmpi/gnu/4.0.2
mpiexec ../jacobi-mpi 100 20000