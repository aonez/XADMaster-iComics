/*
 * XADPlatformiOS.m
 *
 * Copyright (c) 2017-present, MacPaw Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301  USA
 */
#import "XADPlatform.h"
#import "CSFileHandle.h"
#import "NSDateXAD.h"

#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/attr.h>
#import <sys/xattr.h>

struct ResourceOutputArguments
{
    int fd,offset;
};

@implementation XADPlatform

//
// Archive entry extraction.
//

+(XADError)extractResourceForkEntryWithDictionary:(NSDictionary *)dict
unarchiver:(XADUnarchiver *)unarchiver toPath:(NSString *)destpath
{
    const char *cpath=[destpath fileSystemRepresentation];
    int originalpermissions=-1;

    // Open the file for writing, creating it if it doesn't exist.
    // TODO: Does it need to be opened for writing or is read enough?
    int fd=open(cpath,O_WRONLY|O_CREAT|O_NOFOLLOW,0666);
    if(fd==-1)
    {
        // If opening the file failed, check if it is a link and skip if it is.
        struct stat st;
        lstat(cpath,&st);

        if(S_ISLNK(st.st_mode))
        {
            NSNumber *sizenum=[dict objectForKey:XADFileSizeKey];
            if(!sizenum) return XADNoError;
            else if([sizenum longLongValue]==0) return XADNoError;
        }

        // Otherwise, try changing permissions.
        originalpermissions=st.st_mode;

        chmod(cpath,0700);

        fd=open(cpath,O_WRONLY|O_CREAT|O_NOFOLLOW,0666);
        if(fd==-1) return XADOpenFileError; // TODO: Better error.
    }

    struct ResourceOutputArguments args={ .fd=fd, .offset=0 };

    XADError error=[unarchiver runExtractorWithDictionary:dict
    outputTarget:self selector:@selector(outputToResourceFork:bytes:length:)
    argument:[NSValue valueWithPointer:&args]];

    close(fd);

    if(originalpermissions!=-1) chmod(cpath,originalpermissions);

    return error;
}

+(XADError)outputToResourceFork:(NSValue *)pointerval bytes:(uint8_t *)bytes length:(int)length
{
    struct ResourceOutputArguments *args=[pointerval pointerValue];
    if(fsetxattr(args->fd,XATTR_RESOURCEFORK_NAME,bytes,length,
    args->offset,0)) return XADOutputError;

    args->offset+=length;

    return XADNoError;
}

+(XADError)updateFileAttributesAtPath:(NSString *)path
forEntryWithDictionary:(NSDictionary *)dict parser:(XADArchiveParser *)parser
preservePermissions:(BOOL)preservepermissions
{
	const char *cpath=[path fileSystemRepresentation];

	// Read file permissions.
	struct stat st;
	if(lstat(cpath,&st)!=0) return XADOpenFileError; // TODO: better error

	// If the file does not have write permissions, change this temporarily.
	if(!(st.st_mode&S_IWUSR)) chmod(cpath,0700);

	// Write extended attributes.
	NSDictionary *extattrs=[parser extendedAttributesForDictionary:dict];
	if(extattrs)
	{
		NSEnumerator *enumerator=[extattrs keyEnumerator];
		NSString *key;
		while((key=[enumerator nextObject]))
		{
			NSData *data=[extattrs objectForKey:key];

			int namelen=[key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
			char namebytes[namelen+1];
			[key getCString:namebytes maxLength:sizeof(namebytes) encoding:NSUTF8StringEncoding];

			setxattr(cpath,namebytes,[data bytes],[data length],0,XATTR_NOFOLLOW);
		}
	}

	// Attrlist structures.
	struct attrlist list={ ATTR_BIT_MAP_COUNT };
	uint8_t attrdata[3*sizeof(struct timespec)+sizeof(uint32_t)];
	uint8_t *attrptr=attrdata;

	// Handle timestamps.
	NSDate *creation=[dict objectForKey:XADCreationDateKey];
	NSDate *modification=[dict objectForKey:XADLastModificationDateKey];
	NSDate *access=[dict objectForKey:XADLastAccessDateKey];

	if(creation)
	{
		list.commonattr|=ATTR_CMN_CRTIME;
		*((struct timespec *)attrptr)=[creation timespecStruct];
		attrptr+=sizeof(struct timeval);
	}
	if(modification)
	{
		list.commonattr|=ATTR_CMN_MODTIME;
		*((struct timespec *)attrptr)=[modification timespecStruct];
		attrptr+=sizeof(struct timeval);
	}
	if(access)
	{
		list.commonattr|=ATTR_CMN_ACCTIME;
		*((struct timespec *)attrptr)=[access timespecStruct];
		attrptr+=sizeof(struct timeval);
	}

	// Figure out permissions, or reuse the earlier value.
	mode_t mode=st.st_mode;
	NSNumber *permissions=[dict objectForKey:XADPosixPermissionsKey];
	if(permissions)
	{
		mode=[permissions unsignedShortValue];
		if(!preservepermissions)
		{
			mode_t mask=umask(022);
			umask(mask); // This is stupid. Is there no sane way to just READ the umask?
			mode&=~(mask|S_ISUID|S_ISGID);
		}
	}

	// Add permissions to attribute list.
	list.commonattr|=ATTR_CMN_ACCESSMASK;
	*((uint32_t *)attrptr)=mode;
	attrptr+=sizeof(uint32_t);

	// Finally, set all attributes.
	setattrlist(cpath,&list,attrdata,attrptr-attrdata,FSOPT_NOFOLLOW);

	return XADNoError;
}

+(XADError)createLinkAtPath:(NSString *)path withDestinationPath:(NSString *)link
{
	struct stat st;
	const char *destcstr=[path fileSystemRepresentation];
	if(lstat(destcstr,&st)==0) unlink(destcstr);
	if(symlink([link fileSystemRepresentation],destcstr)!=0) return XADLinkError;

	return XADNoError;
}




//
// Archive post-processing.
//

+(id)readCloneableMetadataFromPath:(NSString *)path { return nil; }
+(void)writeCloneableMetadata:(id)metadata toPath:(NSString *)path {}

+(BOOL)copyDateFromPath:(NSString *)src toPath:(NSString *)dest
{
	struct stat st;
	const char *csrc=[src fileSystemRepresentation];
	if(stat(csrc,&st)!=0) return NO;

	struct timeval times[2]={
		{st.st_atimespec.tv_sec,st.st_atimespec.tv_nsec/1000},
		{st.st_mtimespec.tv_sec,st.st_mtimespec.tv_nsec/1000},
	};

	const char *cdest=[dest fileSystemRepresentation];
	if(utimes(cdest,times)!=0) return NO;

	return YES;
}

+(BOOL)resetDateAtPath:(NSString *)path
{
	const char *cpath=[path fileSystemRepresentation];
	if(utimes(cpath,NULL)!=0) return NO;

	return YES;
}



//
// Path functions.
//

+(BOOL)fileExistsAtPath:(NSString *)path { return [self fileExistsAtPath:path isDirectory:NULL]; }

+(BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isdirptr
{
	// [NSFileManager fileExistsAtPath:] is broken. It will happily return NO
	// for some symbolic links. We need to implement our own.

	struct stat st;
	if(lstat([path fileSystemRepresentation],&st)!=0) return NO;

	if(isdirptr)
	{
		if((st.st_mode&S_IFMT)==S_IFDIR) *isdirptr=YES;
		else *isdirptr=NO;
	}

	return YES;
}

+(NSString *)uniqueDirectoryPathWithParentDirectory:(NSString *)parent
{
	// TODO: ensure this path is actually unique.
	NSDate *now=[NSDate date];
	int64_t t=[now timeIntervalSinceReferenceDate]*1000000000;
	pid_t pid=getpid();

	NSString *dirname=[NSString stringWithFormat:@"XADTemp%qd%d",t,pid];

	if(parent) return [parent stringByAppendingPathComponent:dirname];
	else return dirname;
}

+(NSString *)sanitizedPathComponent:(NSString *)component
{
	if([component rangeOfString:@"/"].location==NSNotFound&&
	[component rangeOfString:@"\000"].location==NSNotFound) return component;

	NSMutableString *newstring=[NSMutableString stringWithString:component];
	[newstring replaceOccurrencesOfString:@"/" withString:@":" options:0 range:NSMakeRange(0,[newstring length])];
	[newstring replaceOccurrencesOfString:@"\000" withString:@"_" options:0 range:NSMakeRange(0,[newstring length])];
	return newstring;
}

+(NSArray *)contentsOfDirectoryAtPath:(NSString *)path
{
	return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
}

+(BOOL)moveItemAtPath:(NSString *)src toPath:(NSString *)dest
{
	return [[NSFileManager defaultManager] moveItemAtPath:src toPath:dest error:NULL];
}

+(BOOL)removeItemAtPath:(NSString *)path
{
	return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}



//
// Resource forks
//

+(CSHandle *)handleForReadingResourceForkAtPath:(NSString *)path { return nil; }



//
// Time functions.
//

+(double)currentTimeInSeconds
{
	struct timeval tv;
	gettimeofday(&tv,NULL);
	return (double)tv.tv_sec+(double)tv.tv_usec/1000000.0;
}





@end
