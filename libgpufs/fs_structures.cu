/* 
 * This expermental software is provided AS IS.
 * Feel free to use/modify/distribute,
 * If used, please retain this disclaimer and cite
 * "GPUfs: Integrating a file system with GPUs",
 * M Silberstein,B Ford,I Keidar,E Witchel
 * ASPLOS13, March 2013, Houston,USA
 */

/* 
 * This expermental software is provided AS IS.
 * Feel free to use/modify/distribute,
 * If used, please retain this disclaimer and cite
 * "GPUfs: Integrating a file system with GPUs",
 * M Silberstein,B Ford,I Keidar,E Witchel
 * ASPLOS13, March 2013, Houston,USA
 */

#ifndef FS_STRUCTURES_CU
#define FS_STRUCTURES_CU

#include "fs_structures.cu.h"
#include "fs_globals.cu.h"

DEBUG_NOINLINE __device__ void PFrame::init_thread( volatile Page* _page, int _rs_offset ) volatile
{
	page = _page;
	rs_offset = _rs_offset;
	file_id = (uint) -1;
	content_size = 0;
	file_offset = (uint) -1;
	dirty = 0;
	dirtyCounter = 0;

	lock = 0;
	refCount = 0;
	state = INVALID;
}

DEBUG_NOINLINE __device__ void PFrame::clean() volatile
{
	file_id = (uint) -1;
	content_size = (uint)-1;
	file_offset = (uint) -1;
	dirty = 0;
	dirtyCounter = 0;
}

DEBUG_NOINLINE __device__ bool PFrame::try_lock_init() volatile
{
	if( MUTEX_WAS_LOCKED(lock) )
	{
		// page is busy
		return false;
	}

	if( INVALID == state )
	{
		// We are the ones initiating this page
		state = INIT;
		refCount = 1;
		threadfence();
		// Keep lock
		return true;
	}
	else
	{
		// It is already initiated by someone else
		MUTEX_UNLOCK( lock );
		return false;
	}
}

DEBUG_NOINLINE __device__ void PFrame::unlock_init() volatile
{
	GPU_ASSERT( lock );
	GPU_ASSERT( state == INIT || state == UPDATING );

	state = VALID;
	MUTEX_UNLOCK( lock );
}



DEBUG_NOINLINE __device__ bool PFrame::try_lock_rw( int fd, int _version, size_t offset ) volatile
{
	if( MUTEX_WAS_LOCKED(lock) )
	{
		// page is busy
		return false;
	}

	if( state == PFrame::VALID && fd == file_id && file_offset == offset )
	{
		if( version == _version )
		{
			// This is the right one
			refCount++;
			threadfence();
			MUTEX_UNLOCK( lock );
			return true;
		}
		else
		{
			// Right page but older version
			GPU_ASSERT( version < _version );
			GPU_ASSERT( refCount == 0 );

			state = UPDATING;
			refCount = 1;
			version = _version;
			threadfence();
			// Keep lock
			return true;
		}
	}
	else
	{
		// page is either invalid or point to a different location
		MUTEX_UNLOCK( lock );
		return false;
	}
}

DEBUG_NOINLINE __device__ void PFrame::unlock_rw() volatile
{
	MUTEX_LOCK( lock );
	refCount--;
	MUTEX_UNLOCK( lock );

//	atomicSub((int*)&refCount, 1);
}

DEBUG_NOINLINE __device__ bool PFrame::try_invalidate( int fd, size_t offset ) volatile
{
	if( MUTEX_WAS_LOCKED(lock) )
	{
		// page is busy
		return false;
	}

	if( refCount == 0 && fd == file_id && offset == file_offset )
	{
		// We can safely remove this page
		clean();
		state = INVALID;
		threadfence();
		MUTEX_UNLOCK( lock );
		return true;
	}
	else
	{
		// Someone is still using it, don't invalidate
		MUTEX_UNLOCK( lock );
		return false;
	}
}

DEBUG_NOINLINE __device__ void PFrame::markDirty() volatile
{
	dirty = 1;
}

DEBUG_NOINLINE __device__ void BusyList::init_thread() volatile
{
	_lock = 0;
	count = 0;
	head = NULL;
}

DEBUG_NOINLINE __device__ void BusyList::clean() volatile
{
	count = 0;
	head = NULL;
}

DEBUG_NOINLINE __device__ void BusyList::push( volatile PFrame* frame ) volatile
{
	lock();

	volatile PFrame* temp = (head == NULL) ? NULL : head->nextDirty;
	head = frame;
	frame->nextDirty = temp;

	count++;

	unlock();
}

DEBUG_NOINLINE __device__ void BusyList::lock() volatile
{
	MUTEX_LOCK( _lock );
}

DEBUG_NOINLINE __device__ bool BusyList::try_lock() volatile
{
	return MUTEX_TRY_LOCK(_lock);
}

DEBUG_NOINLINE __device__ void BusyList::unlock() volatile
{
	MUTEX_UNLOCK( _lock );
}

//******* OPEN/CLOSE *//

DEBUG_NOINLINE __device__ void FTable_entry::init_thread() volatile
{
	status = FSENTRY_EMPTY;
	refCount = 0;
	file_id = -1;
	cpu_fd = -1;
	version = 0;
	size = 0;
	drop_cache = 0;
	dirty = 0;
	cpu_timestamp = 0;
}

DEBUG_NOINLINE __device__ void FTable_entry::init( const volatile char* _filename, int _flags ) volatile
{
	strcpy_thread( filename, _filename, FILENAME_SIZE );
	status = FSENTRY_PENDING;
	refCount = 0;
	cpu_fd = -1;
	flags = _flags;
	did_open = 0;
	version++;
}

DEBUG_NOINLINE __device__ void FTable_entry::notify( int fd, int _cpu_fd, size_t _size,
		double timestamp, int _did_open ) volatile
{
	file_id = fd;
	cpu_fd = _cpu_fd;
	size = _size;
	cpu_timestamp = timestamp;
	did_open = _did_open;
	__threadfence();
	status = FSENTRY_OPEN;
	__threadfence();
}

DEBUG_NOINLINE __device__ void FTable_entry::wait_open() volatile
{
	WAIT_ON_MEM( status, FSENTRY_OPEN );
}

DEBUG_NOINLINE __device__ void FTable_entry::traverse_all_for_close() volatile
{
	if ( !dirty ) return;

	busyList.lock();

	while( busyList.head != NULL )
	{
		volatile PFrame* frame = busyList.head;
		if( frame->dirty || frame->dirtyCounter>0 )
		{
			writeback_page_async_on_close(cpu_fd, frame, flags);
			frame->dirty = 0;
			frame->dirtyCounter = 0;
		}

		busyList.head = frame->nextDirty;
		frame->nextDirty = NULL;
	}

	dirty = false;
	writeback_page_async_on_close_done(cpu_fd);

	busyList.unlock();
}

DEBUG_NOINLINE __device__ void FTable_entry::clean() volatile
{
	GPU_ASSERT(refCount==0);
	status = FSENTRY_EMPTY;
	did_open = 0;
	dirty = 0;
}

DEBUG_NOINLINE __device__ void FTable_entry::close() volatile
{
	GPU_ASSERT(refCount==0);
	status = FSENTRY_CLOSED;
	did_open = 0;
	dirty = 0;
}

DEBUG_NOINLINE __device__ void FTable::lock() volatile
{
	MUTEX_LOCK( _lock );
}

DEBUG_NOINLINE __device__ void FTable::unlock() volatile
{
	MUTEX_UNLOCK( _lock );
}

DEBUG_NOINLINE __device__ void FTable::init_thread() volatile
{
	for( int i = 0; i < FSTABLE_SIZE; i++ )
	{
		files[i].init_thread();
		_lock = 0;
	}
}

DEBUG_NOINLINE __device__ int FTable::findEntry( volatile const char* filename, volatile bool* isNewEntry,
		int o_flags ) volatile
{
	*isNewEntry = true;
	int found = E_FSTABLE_FULL;
	int foundClosed = E_FSTABLE_FULL;

	for( int i = 0; i < FSTABLE_SIZE; i++ )
	{
		if( (found == E_FSTABLE_FULL) && (files[i].status == FSENTRY_EMPTY) )
		{
			found = i;
		}
		else if( !strcmp_thread( filename, files[i].filename, FILENAME_SIZE ) )
		{
			// found entry
			found = i;
			*isNewEntry = false;
			break;
		}
		else if( (foundClosed == E_FSTABLE_FULL) && (files[i].status == FSENTRY_CLOSED) )
		{
			foundClosed = i;
		}
	}

	if( *isNewEntry )
	{
		if( found != E_FSTABLE_FULL )
		{
			files[found].init( filename, o_flags );
			__threadfence();
			return found;
		}
		else if( foundClosed != E_FSTABLE_FULL )
		{
			files[foundClosed].init( filename, o_flags );
			__threadfence();
			return foundClosed;
		}
	}

	return found;
}
#endif
