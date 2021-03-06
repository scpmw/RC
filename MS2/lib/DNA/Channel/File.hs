{-# LANGUAGE DeriveDataTypeable, DeriveGeneric, BangPatterns #-}

module DNA.Channel.File (
          itemSize
        , readData, readDataMMap, roundUpDiv
        , chunkOffset, chunkSize
        ) where

import Data.Vector.Binary ()

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as MS

import Foreign
import Foreign.C.Types
import Foreign.C.String



-- XXX Let's have 8 space indents everywhere
itemSize :: Int64
itemSize = 8
-- divide up a file in chunkCount chunks
-- functions to read chunkSize * itemSize from a file at offset chunkSize * itemSize
roundUpDiv :: Int64 -> Int64 -> Int64
roundUpDiv a b = - div (-a) b

chunkOffset :: Int64 -> Int64 -> Int64 -> Int64
chunkOffset chunkCount itemCount chunkNo
        | chunkNo > chunkCount || chunkNo < 1 = -1
        | otherwise = itemSize * (chunkNo -1 ) * roundUpDiv itemCount chunkCount


chunkSize :: Int64 -> Int64 -> Int64 -> Int64
chunkSize cC iC cN
        |  cN < 1 || cN > cC = 0
        |  cN > div iC (roundUpDiv iC cC) = iC - (cN -1) * (roundUpDiv iC cC)
        |  otherwise = roundUpDiv iC cC

-- read a buffer from a file into pinned memory
-- arguments: buffer ptr, size, offset, path
foreign import ccall unsafe "read_data"
    c_read_data :: Ptr CDouble -> CLong -> CLong -> CString -> IO ()

-- read a buffer from a file into mmapped memory.
-- arguments: size (num of elements of double type), offset, path
foreign import ccall unsafe "read_data_mmap"
    c_read_data_mmap :: CLong -> CLong -> CString -> CString -> IO (Ptr CDouble)

-- Unmap buffer fir the vector
foreign import ccall unsafe "&munmap_data"
    c_munmap_data :: FunPtr (Ptr CLong -> Ptr CDouble -> IO ())

readData :: Int64 -> Int64 -> String -> IO (S.Vector Double)
readData n o p = do
    mv <- MS.new (fromIntegral n) :: IO (MS.IOVector Double)
    MS.unsafeWith mv $ \ptr ->
        -- Here I assume that CDouble and Double are same thing (it is)
        -- and blindly cast pointer
        withCString p (c_read_data (castPtr ptr) (fromIntegral n) (fromIntegral o))
    S.unsafeFreeze mv

readDataMMap :: Int64 -> Int64 -> String -> String -> IO (S.Vector Double)
readDataMMap n o p nodeId =
    withCString p      $ \path ->
    withCString nodeId $ \nodeStr -> do
        ptr  <- c_read_data_mmap (fromIntegral n) (fromIntegral o) path nodeStr
        -- NOTE: pointer with length is freed in c_munmap_data
        nPtr <- new (fromIntegral n :: CLong)
        fptr <- newForeignPtrEnv c_munmap_data nPtr ptr
        return $ S.unsafeFromForeignPtr0 (castForeignPtr fptr) (fromIntegral n)
